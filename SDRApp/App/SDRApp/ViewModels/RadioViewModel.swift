import Foundation
import Observation
import Metal
import SDRModels
import SDRSupport
import RTLTCPClientKit
import SDRCoreDSP
import AudioEngineKit
import SDRRender

private final class FFTFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latestBins: [Float]?

    func push(_ bins: [Float]) {
        lock.lock()
        latestBins = bins
        lock.unlock()
    }

    func popLatest() -> [Float]? {
        lock.lock()
        let bins = latestBins
        latestBins = nil
        lock.unlock()
        return bins
    }

    func clear() {
        lock.lock()
        latestBins = nil
        lock.unlock()
    }
}

/// Main view model coordinating all SDR subsystems.
@Observable
@MainActor
final class RadioViewModel {
    // MARK: - State

    var frequencyHz: Int = 100_000_000
    var mode: DemodMode = .wfm
    var bandwidthHz: Int = 200_000
    var stepHz: Int = 100_000
    // UI squelch amount: 0 = open, 1 = tight.
    var squelchLevel: Float = 0
    var gainMode: GainMode = .auto
    var gainValue: Float = 0
    var ppm: Float = 0
    var bfoOffset: Float = 0 // Hz, for SSB/CW fine tune

    var isConnected: Bool = false
    var isPlaying: Bool = false
    var connectionState: ConnectionState = .disconnected
    var isRadioTabVisible: Bool = true
    var isDirectSamplingActive: Bool = false
    var directSamplingMode: DirectSamplingMode = .off
    var isNetworkPoor: Bool = false
    var networkQualityHint: String = "Idle"

    // Diagnostics
    var throughputMbps: Double = 0
    var iqBufferFill: Double = 0
    var audioBufferFill: Double = 0
    var currentFPS: Double = 0
    var squelchNoiseLevel: Float = 0

    // Spectrum
    let spectrumProcessor = SpectrumProcessor()

    // MARK: - Subsystems

    let iqBuffer = IQRingBuffer(capacity: 4 * 1_024_000) // ~2 sec at 1MSPS 8-bit IQ
    let audioBuffer = AudioRingBuffer(capacity: 96_000)    // 2 sec at 48kHz
    let connection: RTLTCPConnection
    let dspPipeline: DSPPipeline
    let audioEngine: SDRAudioEngine
    let discovery = ServiceDiscovery()
    let diagnostics = DiagnosticsCollector()
    let scanEngine = ScanEngine()

    var waterfallRenderer: WaterfallRenderer?

    private var diagnosticsTimer: Timer?
    private var fftUITimer: Timer?
    private let directSamplingThresholdHz = 24_000_000
    private let iqBytesPerSamplePair: Double = 2.0
    private let fftMailbox = FFTFrameMailbox()
    private var dspFFTHandler: (([Float], Int) -> Void)?
    private var poorNetworkStreak: Int = 0
    private var goodNetworkStreak: Int = 0
    private var lastIQUnderrunCount: Int = 0
    private var lastAudioUnderrunCount: Int = 0

    init() {
        connection = RTLTCPConnection(iqBuffer: iqBuffer)
        dspPipeline = DSPPipeline(iqBuffer: iqBuffer, audioBuffer: audioBuffer)
        audioEngine = SDRAudioEngine(audioBuffer: audioBuffer)

        // DSP pushes FFT frames into mailbox; UI pulls at a fixed frame rate.
        let mailbox = self.fftMailbox
        let fftHandler: ([Float], Int) -> Void = { bins, _ in
            mailbox.push(bins)
        }
        self.dspFFTHandler = fftHandler
        dspPipeline.onFFTFrame = fftHandler

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
            waterfallRenderer?.setRenderingActive(false)
        }

        startFFTUITimer()
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
        diagnosticsTimer = nil
        isConnected = false
        connectionState = .disconnected
        throughputMbps = 0
        iqBufferFill = 0
        audioBufferFill = 0
        currentFPS = 0
        squelchNoiseLevel = 0
        resetNetworkQualityState(hint: "Idle")
    }

    func testConnection(host: String, port: UInt16) async -> Result<RTLTCPHeader, Error> {
        if connection.isConnected(to: host, port: port) {
            if case .connected(let header) = connection.state {
                return .success(header)
            }
            if let header = connection.header {
                return .success(header)
            }
        }
        return await connection.testConnection(host: host, port: port)
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
        applyDirectSamplingForCurrentFrequency()
        connection.setFrequency(UInt32(frequencyHz))
        connection.setSampleRate(UInt32(dspPipeline.sampleRate))
        connection.setGainMode(gainMode)
        connection.setAGCMode(gainMode == .auto)
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
        dspPipeline.setSquelch(squelchThreshold(for: squelchLevel))

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
        if isRadioTabVisible {
            dspPipeline.onFFTFrame = dspFFTHandler
        }
        waterfallRenderer?.setRenderingActive(isRadioTabVisible)
        updateNowPlaying()
    }

    func stopListening() {
        scanEngine.stop()
        dspPipeline.stop()
        audioEngine.stop()
        iqBuffer.flush()
        audioBuffer.flush()
        isPlaying = false
        dspPipeline.onFFTFrame = nil
        waterfallRenderer?.setRenderingActive(false)
        fftMailbox.clear()
        resetNetworkQualityState(hint: "Idle")
    }

    // MARK: - Tuning

    func setFrequency(_ hz: Int) {
        frequencyHz = hz
        applyDirectSamplingForCurrentFrequency()
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
        connection.setAGCMode(mode == .auto)
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
        dspPipeline.setSquelch(squelchThreshold(for: level))
    }

    func setBFOOffset(_ hz: Float) {
        bfoOffset = hz
        dspPipeline.bfoOffsetHz = hz
    }

    func setRadioTabVisible(_ isVisible: Bool) {
        isRadioTabVisible = isVisible
        let shouldRender = isVisible && isPlaying
        waterfallRenderer?.setRenderingActive(shouldRender)
        if shouldRender {
            dspPipeline.onFFTFrame = dspFFTHandler
        } else {
            dspPipeline.onFFTFrame = nil
            fftMailbox.clear()
        }
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
                self.squelchNoiseLevel = self.dspPipeline.squelchNoiseLevel
                self.isConnected = {
                    if case .connected = self.connection.state { return true }
                    return false
                }()
                self.connectionState = self.connection.state
                self.updateNetworkQuality()
            }
        }
        if let diagnosticsTimer {
            RunLoop.main.add(diagnosticsTimer, forMode: .common)
        }
    }

    private func startFFTUITimer() {
        fftUITimer?.invalidate()
        fftUITimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainLatestFFTFrameForUI()
            }
        }
        if let fftUITimer {
            RunLoop.main.add(fftUITimer, forMode: .common)
        }
    }

    private func drainLatestFFTFrameForUI() {
        guard isPlaying, isRadioTabVisible else { return }
        guard let bins = fftMailbox.popLatest() else { return }
        spectrumProcessor.update(bins: bins)
        let normalized = spectrumProcessor.normalizedBins()
        waterfallRenderer?.addWaterfallRow(normalized)
        waterfallRenderer?.updateSpectrumBins(normalized)
    }

    // MARK: - Helpers

    private func desiredDirectSamplingMode(for frequencyHz: Int) -> DirectSamplingMode {
        frequencyHz < directSamplingThresholdHz ? .qBranch : .off
    }

    private func squelchThreshold(for uiLevel: Float) -> Float {
        let clamped = max(0, min(1, uiLevel))
        // Invert slider semantics so higher UI level means tighter squelch.
        return 1 - clamped
    }

    private func applyDirectSamplingForCurrentFrequency() {
        let mode = desiredDirectSamplingMode(for: frequencyHz)
        directSamplingMode = mode
        isDirectSamplingActive = mode != .off
        connection.setDirectSampling(mode)
    }

    private func updateNetworkQuality() {
        guard isPlaying else {
            resetNetworkQualityState(hint: "Idle")
            return
        }

        let iqUnderruns = iqBuffer.underrunCount
        let audioUnderruns = audioBuffer.underrunCount
        let hadNewUnderrun = iqUnderruns > lastIQUnderrunCount || audioUnderruns > lastAudioUnderrunCount
        lastIQUnderrunCount = iqUnderruns
        lastAudioUnderrunCount = audioUnderruns

        let expectedThroughputBytes = Double(dspPipeline.sampleRate) * iqBytesPerSamplePair
        let lowThroughput = connection.throughputBytesPerSec < expectedThroughputBytes * 0.65
        let lowIQBuffer = iqBufferFill < 0.10
        let lowAudioBuffer = audioBufferFill < 0.05

        var issueHint: String?
        if hadNewUnderrun {
            issueHint = "Underruns detected"
        } else if lowIQBuffer || lowAudioBuffer {
            issueHint = "Buffers draining"
        } else if lowThroughput {
            issueHint = "Low TCP throughput"
        }

        if let issueHint {
            poorNetworkStreak += 1
            goodNetworkStreak = 0
            networkQualityHint = issueHint
            if poorNetworkStreak >= 3 {
                isNetworkPoor = true
            }
        } else {
            goodNetworkStreak += 1
            poorNetworkStreak = 0
            if goodNetworkStreak >= 4 {
                isNetworkPoor = false
                networkQualityHint = "Good"
            }
        }
    }

    private func resetNetworkQualityState(hint: String) {
        isNetworkPoor = false
        networkQualityHint = hint
        poorNetworkStreak = 0
        goodNetworkStreak = 0
        lastIQUnderrunCount = iqBuffer.underrunCount
        lastAudioUnderrunCount = audioBuffer.underrunCount
    }

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
