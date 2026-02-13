import Foundation
import Observation
import Metal
import SDRModels
import SDRSupport
import RTLTCPClientKit
import SDRCoreDSP
import AudioEngineKit
import SDRRender

/// Main view model coordinating all SDR subsystems.
@Observable
@MainActor
final class RadioViewModel {
    // MARK: - State

    var frequencyHz: Int = 100_000_000
    var mode: DemodMode = .wfm
    var bandwidthHz: Int = 200_000
    var stepHz: Int = 100_000
    var squelchLevel: Float = 0
    var gainMode: GainMode = .auto
    var gainValue: Float = 0
    var ppm: Float = 0
    var bfoOffset: Float = 0 // Hz, for SSB/CW fine tune

    var isConnected: Bool = false
    var isPlaying: Bool = false
    var connectionState: ConnectionState = .disconnected

    // Diagnostics
    var throughputMbps: Double = 0
    var iqBufferFill: Double = 0
    var audioBufferFill: Double = 0
    var currentFPS: Double = 0

    // Spectrum
    let spectrumProcessor = SpectrumProcessor()

    // MARK: - Subsystems

    let iqBuffer = IQRingBuffer(capacity: 2 * 1_024_000) // ~1 sec at 1MSPS 8-bit IQ
    let audioBuffer = AudioRingBuffer(capacity: 48000)     // 1 sec at 48kHz
    let connection: RTLTCPConnection
    let dspPipeline: DSPPipeline
    let audioEngine: SDRAudioEngine
    let discovery = ServiceDiscovery()
    let diagnostics = DiagnosticsCollector()
    let scanEngine = ScanEngine()

    var waterfallRenderer: WaterfallRenderer?

    private var diagnosticsTimer: Timer?

    init() {
        connection = RTLTCPConnection(iqBuffer: iqBuffer)
        dspPipeline = DSPPipeline(iqBuffer: iqBuffer, audioBuffer: audioBuffer)
        audioEngine = SDRAudioEngine(audioBuffer: audioBuffer)

        // Setup FFT callback (called from DSP thread — dispatch to main)
        dspPipeline.onFFTFrame = { [weak self] bins, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.spectrumProcessor.update(bins: bins)
                let normalized = self.spectrumProcessor.normalizedBins()
                self.waterfallRenderer?.addWaterfallRow(normalized)
                self.waterfallRenderer?.updateSpectrumBins(normalized)
            }
        }

        // Lock screen callbacks
        audioEngine.onPlayPause = { [weak self] in
            if self?.isPlaying == true {
                self?.stopListening()
            } else {
                self?.startListening()
            }
        }
        audioEngine.onNextStation = { [weak self] in
            self?.stepFrequency(up: true)
        }
        audioEngine.onPreviousStation = { [weak self] in
            self?.stepFrequency(up: false)
        }

        // Create Metal renderer
        if let device = MTLCreateSystemDefaultDevice() {
            waterfallRenderer = WaterfallRenderer(device: device)
        }
    }

    // MARK: - Connection

    func connect(host: String, port: UInt16) {
        print("📻 RadioViewModel.connect(\(host):\(port))")
        connection.connect(host: host, port: port)
        startDiagnosticsTimer()
    }

    func disconnect() {
        stopListening()
        connection.disconnect()
        diagnosticsTimer?.invalidate()
    }

    func testConnection(host: String, port: UInt16) async -> Result<RTLTCPHeader, Error> {
        await connection.testConnection(host: host, port: port)
    }

    // MARK: - Listening

    func startListening() {
        print("📻 startListening called, connection.state=\(connection.state)")
        guard case .connected = connection.state else {
            print("📻 startListening: NOT connected, aborting")
            return
        }
        print("📻 startListening: connected, proceeding")

        // Send initial commands
        connection.setFrequency(UInt32(frequencyHz))
        connection.setSampleRate(UInt32(dspPipeline.sampleRate))
        connection.setGainMode(gainMode)
        if gainMode == .manual {
            connection.setGain(UInt32(gainValue * 10))
        }
        if ppm != 0 {
            connection.setPPM(Int32(ppm))
        }

        // Configure DSP
        dspPipeline.mode = mode
        dspPipeline.bandwidthHz = bandwidthHz
        dspPipeline.bfoOffsetHz = bfoOffset
        dspPipeline.setSquelch(squelchLevel)

        // Start audio
        do {
            try audioEngine.configureSession()
            try audioEngine.start()
        } catch {
            SDRLogger.audio.error("Failed to start audio: \(error)")
            return
        }

        // Start DSP
        dspPipeline.start()

        isPlaying = true
        updateNowPlaying()
    }

    func stopListening() {
        scanEngine.stop()
        dspPipeline.stop()
        audioEngine.stop()
        iqBuffer.flush()
        audioBuffer.flush()
        isPlaying = false
    }

    // MARK: - Tuning

    func setFrequency(_ hz: Int) {
        frequencyHz = hz
        connection.setFrequency(UInt32(hz))
        dspPipeline.resetState()
        updateNowPlaying()
    }

    func stepFrequency(up: Bool) {
        let newFreq = up ? frequencyHz + stepHz : frequencyHz - stepHz
        setFrequency(max(1_000, newFreq)) // Minimum 1 kHz
    }

    func setMode(_ newMode: DemodMode) {
        mode = newMode
        stepHz = newMode.defaultStepHz
        bandwidthHz = newMode.defaultBandwidthHz
        dspPipeline.mode = newMode
        dspPipeline.bandwidthHz = bandwidthHz
        dspPipeline.resetState()
        audioBuffer.flush()
        updateNowPlaying()
    }

    func setBandwidth(_ hz: Int) {
        bandwidthHz = hz
        dspPipeline.bandwidthHz = hz
    }

    func setGain(mode: GainMode, value: Float) {
        self.gainMode = mode
        self.gainValue = value
        connection.setGainMode(mode)
        if mode == .manual {
            connection.setGain(UInt32(value * 10))
        }
    }

    func setPPM(_ value: Float) {
        ppm = value
        connection.setPPM(Int32(value))
    }

    func setSquelch(_ level: Float) {
        squelchLevel = level
        dspPipeline.setSquelch(level)
    }

    func setBFOOffset(_ hz: Float) {
        bfoOffset = hz
        dspPipeline.bfoOffsetHz = hz
    }

    // MARK: - Now Playing

    private func updateNowPlaying() {
        let freqStr = formatFrequency(frequencyHz)
        audioEngine.nowPlayingTitle = "\(freqStr) \(mode.displayName)"
        audioEngine.nowPlayingSubtitle = "SDR Radio"
    }

    // MARK: - Diagnostics

    private func startDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.throughputMbps = self.connection.throughputBytesPerSec * 8 / 1_000_000
                self.iqBufferFill = self.iqBuffer.fillLevel
                self.audioBufferFill = self.audioBuffer.fillLevel
                self.currentFPS = self.waterfallRenderer?.currentFPS ?? 0
                self.isConnected = {
                    if case .connected = self.connection.state { return true }
                    return false
                }()
                self.connectionState = self.connection.state
            }
        }
    }

    // MARK: - Helpers

    func formatFrequency(_ hz: Int) -> String {
        if hz >= 1_000_000_000 {
            return String(format: "%.6f GHz", Double(hz) / 1_000_000_000)
        } else if hz >= 1_000_000 {
            return String(format: "%.6f MHz", Double(hz) / 1_000_000)
        } else if hz >= 1_000 {
            return String(format: "%.3f kHz", Double(hz) / 1_000)
        } else {
            return "\(hz) Hz"
        }
    }
}
