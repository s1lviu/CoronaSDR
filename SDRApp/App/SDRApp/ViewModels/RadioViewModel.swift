import Foundation
import Observation
import Metal
import QuartzCore
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
    var isAppActive: Bool = true

    // Diagnostics
    var throughputMbps: Double = 0
    var iqBufferFill: Double = 0
    var audioBufferFill: Double = 0
    var currentFPS: Double = 0
    var squelchNoiseLevel: Float = 0

    // Spectrum
    let spectrumProcessor = SpectrumProcessor()

    // MARK: - Subsystems

    // Larger jitter buffers reduce audible dropouts when iOS briefly deprioritizes background work.
    let iqBuffer = IQRingBuffer(capacity: 12 * 1_024_000) // ~6 sec at 1MSPS 8-bit IQ, ~2.5 sec at 2.4MSPS
    let audioBuffer = AudioRingBuffer(capacity: 240_000)   // 5 sec at 48kHz
    let connection: RTLTCPConnection
    let dspPipeline: DSPPipeline
    let audioEngine: SDRAudioEngine
    let discovery = ServiceDiscovery()
    let scanEngine = ScanEngine()

    var waterfallRenderer: WaterfallRenderer?

    private var diagnosticsTimer: Timer?
    private var fftDisplayLink: CADisplayLink?
    private let directSamplingThresholdHz = 24_000_000
    private let iqBytesPerSamplePair: Double = 2.0
    private let fftMailbox = FFTFrameMailbox()
    private var dspFFTHandler: (([Float], Int) -> Void)?
    private var poorNetworkStreak: Int = 0
    private var goodNetworkStreak: Int = 0
    private var lastIQUnderrunCount: Int = 0
    private var lastAudioUnderrunCount: Int = 0
    private var preferredSampleRate: Int = 1_024_000
    private var preferredFFTSize: Int = 2048
    private var effectiveSampleRate: Int = 1_024_000
    private var effectiveFFTSize: Int = 2048
    private var preferredUIFPS: Int = 20
    private var effectiveUIFPS: Int = 20
    private var lastWaterfallRow: [Float] = []
    private var powerModeObserver: NSObjectProtocol?
    private var thermalStateObserver: NSObjectProtocol?

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
        dspPipeline.setFFTFrameRate(effectiveUIFPS)
        waterfallRenderer?.targetFPS = effectiveUIFPS
        setupPowerAndThermalObservers()
        applyPerformancePolicy()

        // Scan callbacks
        scanEngine.onTune = { [weak self] frequencyHz, mode in
            guard let self else { return }
            self.setMode(mode)
            self.setFrequency(frequencyHz)
            if !self.isPlaying {
                self.startListening()
            }
        }
        scanEngine.onSquelchCheck = { [weak self] in
            guard let self else { return false }
            guard self.isPlaying, self.mode.supportsSquelch else { return false }
            return self.dspPipeline.isSquelchOpen
        }

        updateFFTUITimerState()
    }

    @MainActor deinit {
        diagnosticsTimer?.invalidate()
        fftDisplayLink?.invalidate()
        if let powerModeObserver {
            NotificationCenter.default.removeObserver(powerModeObserver)
        }
        if let thermalStateObserver {
            NotificationCenter.default.removeObserver(thermalStateObserver)
        }
    }

    // MARK: - Connection

    func connect(host: String, port: UInt16) {
        SDRDebug.print("📻 RadioViewModel.connect(\(host):\(port))")
        connection.connect(host: host, port: port)
        updateDiagnosticsTimerState()
    }

    func disconnect() {
        stopListening()
        connection.disconnect()
        updateDiagnosticsTimerState()
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
        SDRDebug.print("📻 startListening called, connection.state=\(connection.state)")
        guard case .connected = connection.state else {
            SDRDebug.print("📻 startListening: NOT connected, aborting")
            return
        }
        SDRDebug.print("📻 startListening: connected, proceeding")

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
        updateDiagnosticsTimerState()
        updateFFTUITimerState()
        updateNowPlaying()
    }

    func setAppActive(_ isActive: Bool) {
        isAppActive = isActive
        if !isActive {
            scanEngine.stop()
        }
        if !isActive && !isPlaying {
            disconnect()
            return
        }
        updateDiagnosticsTimerState()
        if !isActive {
            updateFFTUITimerState()
        }
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
        updateDiagnosticsTimerState()
        updateFFTUITimerState()
        fftMailbox.clear()
        lastWaterfallRow.removeAll(keepingCapacity: true)
        resetNetworkQualityState(hint: "Idle")
    }

    // MARK: - Scan

    func startListScan(frequencies: [(hz: Int, mode: DemodMode)], dwellMs: Int, holdSec: Int) -> Bool {
        guard case .connected = connection.state else { return false }
        if !isPlaying {
            startListening()
            guard isPlaying else { return false }
        }
        scanEngine.startListScan(
            frequencies: frequencies,
            dwellMs: max(100, dwellMs),
            holdSec: max(1, holdSec)
        )
        return true
    }

    func startRangeScan(
        startHz: Int,
        endHz: Int,
        stepHz: Int,
        mode: DemodMode,
        dwellMs: Int,
        holdSec: Int
    ) -> Bool {
        guard case .connected = connection.state else { return false }
        if !isPlaying {
            startListening()
            guard isPlaying else { return false }
        }
        scanEngine.startRangeScan(
            startHz: startHz,
            endHz: endHz,
            stepHz: max(1, stepHz),
            mode: mode,
            dwellMs: max(100, dwellMs),
            holdSec: max(1, holdSec)
        )
        return true
    }

    func stopScan() {
        scanEngine.stop()
    }

    func skipScanStep() {
        scanEngine.skip()
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

    var squelchThresholdDBFS: Float? {
        guard squelchLevel > 0 else { return nil }
        return linearToDBFS(squelchThreshold(for: squelchLevel))
    }

    var squelchNoiseDBFS: Float {
        linearToDBFS(squelchNoiseLevel)
    }

    func setBFOOffset(_ hz: Float) {
        bfoOffset = hz
        dspPipeline.bfoOffsetHz = hz
    }

    func applySampleProfile(label: String) {
        let profile = sampleProfile(for: label)
        preferredSampleRate = profile.sampleRate
        preferredFFTSize = profile.fftSize
        preferredUIFPS = profile.uiFps
        applyPerformancePolicy()
    }

    func applySpectrumPeakHold(_ enabled: Bool) {
        spectrumProcessor.peakHoldEnabled = enabled
        if !enabled {
            spectrumProcessor.peakBins = []
        }
    }

    func applyWaterfallColorScheme(_ schemeName: String) {
        waterfallRenderer?.setColorScheme(named: schemeName)
    }

    func applyDeemphasis(_ microseconds: Int) {
        dspPipeline.setDeemphasisUs(microseconds)
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
            lastWaterfallRow.removeAll(keepingCapacity: true)
        }
        updateDiagnosticsTimerState()
        updateFFTUITimerState()
    }

    // MARK: - Now Playing

    private func updateNowPlaying() {
        let freqStr = formatFrequency(frequencyHz)
        audioEngine.nowPlayingTitle = "\(freqStr) \(mode.displayName)"
        audioEngine.nowPlayingSubtitle = "CoronaSDR"
    }

    // MARK: - Diagnostics

    private func startDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
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

    private func updateDiagnosticsTimerState() {
        let isConnectionActive: Bool = {
            switch connection.state {
            case .connected, .connecting, .validatingHeader, .reconnecting:
                return true
            case .disconnected, .failed:
                return false
            }
        }()
        let shouldRun = isAppActive && (isPlaying || (isRadioTabVisible && isConnectionActive))

        if shouldRun {
            if diagnosticsTimer == nil {
                startDiagnosticsTimer()
            }
        } else {
            diagnosticsTimer?.invalidate()
            diagnosticsTimer = nil
        }
    }

    private func startFFTUITimer() {
        fftDisplayLink?.invalidate()

        let displayLink = CADisplayLink(target: self, selector: #selector(handleFFTDisplayLinkTick))
        if #available(iOS 15.0, *) {
            let fps = Float(max(1, effectiveUIFPS))
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: fps,
                maximum: fps,
                preferred: fps
            )
        } else {
            displayLink.preferredFramesPerSecond = max(1, effectiveUIFPS)
        }
        displayLink.add(to: .main, forMode: .common)
        fftDisplayLink = displayLink
    }

    @objc private func handleFFTDisplayLinkTick() {
        drainLatestFFTFrameForUI()
    }

    private func setupPowerAndThermalObservers() {
        powerModeObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                self?.applyPerformancePolicy()
            }
        }

        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                self?.applyPerformancePolicy()
            }
        }
    }

    private func applyPerformancePolicy() {
        let processInfo = ProcessInfo.processInfo
        let lowPower = processInfo.isLowPowerModeEnabled
        let thermalState = processInfo.thermalState

        // UI FPS policy
        let clampedPreferredFPS = max(5, min(60, preferredUIFPS))
        let targetFPS: Int
        switch thermalState {
        case .critical:
            targetFPS = min(clampedPreferredFPS, 12)
        case .serious:
            targetFPS = min(clampedPreferredFPS, 20)
        case .fair:
            targetFPS = min(clampedPreferredFPS, lowPower ? 24 : 45)
        case .nominal:
            targetFPS = lowPower ? min(clampedPreferredFPS, 30) : clampedPreferredFPS
        @unknown default:
            targetFPS = lowPower ? min(clampedPreferredFPS, 30) : clampedPreferredFPS
        }

        dspPipeline.setFFTFrameRate(targetFPS)
        waterfallRenderer?.targetFPS = targetFPS

        if effectiveUIFPS != targetFPS {
            effectiveUIFPS = targetFPS
            if fftDisplayLink != nil {
                startFFTUITimer()
            }
        }

        // DSP/RF load policy
        let sampleRateCap: Int
        switch thermalState {
        case .critical:
            sampleRateCap = 512_000
        case .serious:
            sampleRateCap = 1_024_000
        case .fair:
            sampleRateCap = lowPower ? 1_024_000 : Int.max
        case .nominal:
            sampleRateCap = lowPower ? 1_024_000 : Int.max
        @unknown default:
            sampleRateCap = lowPower ? 1_024_000 : Int.max
        }

        let targetSampleRate = min(preferredSampleRate, sampleRateCap)
        let targetFFTSize: Int = {
            let desired = preferredFFTSize
            if targetSampleRate <= 512_000 {
                return min(desired, 1024)
            }
            if targetSampleRate <= 1_024_000 {
                return min(desired, 2048)
            }
            return desired
        }()

        var dspConfigChanged = false
        if effectiveSampleRate != targetSampleRate {
            effectiveSampleRate = targetSampleRate
            dspPipeline.setSampleRate(targetSampleRate)
            if case .connected = connection.state {
                connection.setSampleRate(UInt32(targetSampleRate))
            }
            dspConfigChanged = true
        }

        if effectiveFFTSize != targetFFTSize {
            effectiveFFTSize = targetFFTSize
            dspPipeline.setFFTSize(targetFFTSize)
            dspConfigChanged = true
        }

        if dspConfigChanged, isPlaying {
            iqBuffer.flush()
            audioBuffer.flush()
        }
    }

    private func updateFFTUITimerState() {
        let shouldRun = isPlaying && isRadioTabVisible
        if shouldRun {
            if fftDisplayLink == nil {
                startFFTUITimer()
            }
        } else {
            fftDisplayLink?.invalidate()
            fftDisplayLink = nil
        }
    }

    private func drainLatestFFTFrameForUI() {
        guard isPlaying, isRadioTabVisible else { return }
        if let bins = fftMailbox.popLatest() {
            spectrumProcessor.update(bins: bins)
            let normalized = spectrumProcessor.normalizedBins()
            waterfallRenderer?.addWaterfallRow(normalized)
            if lastWaterfallRow.count != normalized.count {
                lastWaterfallRow = normalized
            } else {
                lastWaterfallRow.withUnsafeMutableBufferPointer { dst in
                    normalized.withUnsafeBufferPointer { src in
                        dst.baseAddress!.update(from: src.baseAddress!, count: normalized.count)
                    }
                }
            }
        } else if !lastWaterfallRow.isEmpty {
            waterfallRenderer?.addWaterfallRow(lastWaterfallRow)
        }
    }

    // MARK: - Helpers

    private func desiredDirectSamplingMode(for frequencyHz: Int) -> DirectSamplingMode {
        frequencyHz < directSamplingThresholdHz ? .qBranch : .off
    }

    private func squelchThreshold(for uiLevel: Float) -> Float {
        let clamped = max(0, min(1, uiLevel))
        // UI semantics:
        // - 0.0 => always open
        // - 1.0 => tightest squelch (but not forced-open due to zero threshold edge case)
        if clamped <= 0 { return 0 }

        // Invert slider so higher UI means tighter (lower threshold),
        // and keep a small floor to avoid threshold == 0.
        return max(0.001, 1 - clamped)
    }

    private func linearToDBFS(_ value: Float) -> Float {
        let clamped = max(1e-9, value)
        return 20 * log10(clamped)
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

    private func sampleProfile(for label: String) -> (sampleRate: Int, fftSize: Int, uiFps: Int) {
        switch label {
        case "Ultra Low":
            return (250_000, 1024, 12)
        case "Medium":
            return (2_048_000, 4096, 24)
        case "High":
            return (2_400_000, 4096, 30)
        default:
            return (1_024_000, 2048, 20)
        }
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
