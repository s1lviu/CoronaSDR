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

struct ReceiverTuningPlan: Equatable {
    let requestedFrequencyHz: Int
    let tunerFrequencyHz: Int
    let softwareFrequencyShiftHz: Int

    static func make(
        requestedFrequencyHz: Int,
        sampleRateHz: Int,
        supportsHardwareOffsetTuning: Bool,
        hardwareOffsetTuningEnabled: Bool,
        directSamplingActive: Bool,
        maximumFrequencyHz: Int
    ) -> ReceiverTuningPlan {
        let requested = max(0, min(maximumFrequencyHz, requestedFrequencyHz))
        let hardwareOffsetActive = supportsHardwareOffsetTuning && hardwareOffsetTuningEnabled
        let canUseSoftwareOffset = !hardwareOffsetActive && !directSamplingActive && sampleRateHz > 0
        let requestedOffset = canUseSoftwareOffset ? max(0, sampleRateHz / 4) : 0
        let availableUpperOffset = max(0, maximumFrequencyHz - requested)
        let appliedOffset = min(requestedOffset, availableUpperOffset)

        return ReceiverTuningPlan(
            requestedFrequencyHz: requested,
            tunerFrequencyHz: requested + appliedOffset,
            softwareFrequencyShiftHz: -appliedOffset
        )
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
    var directSamplingPreference: DirectSamplingPreference = .auto
    var isDirectSamplingActive: Bool = false
    var directSamplingMode: DirectSamplingMode = .off
    var supportsDirectSamplingAuto: Bool = false
    var supportsManualDirectSampling: Bool = true
    var isOffsetTuningEnabled: Bool = false
    var isBiasTeeEnabled: Bool = false
    var supportsOffsetTuning: Bool = true
    var supportsBiasTee: Bool = false
    var isNetworkPoor: Bool = false
    var isAudioStarving: Bool = false
    var networkQualityHint: String = "Idle"
    var isAppActive: Bool = true
    var audioHighPassHz: Int = 0
    var audioLowPassHz: Int = 0
    var noiseBlankerThreshold: Float = 0
    var audioAgcEnabled: Bool = false
    var waterfallZoom: Double = 1.0

    // Diagnostics
    var throughputMbps: Double = 0
    var iqBufferFill: Double = 0
    var audioBufferFill: Double = 0
    var audioHeadroomMs: Double = 0
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
    let scanEngine = ScanEngine()

    var waterfallRenderer: WaterfallRenderer?

    private var diagnosticsTimer: Timer?
    private var fftDisplayLink: CADisplayLink?
    private let directSamplingThresholdHz = 24_000_000
    private let maxTunableFrequencyHz = Int(UInt32.max)
    private let minimumSampleRateHz = 192_000
    private let minimumWFMSampleRateHz = 250_000
    private let maxAudioFilterCutoffHz = 20_000
    private let minAudioFilterGapHz = 150
    private let iqBytesPerSamplePair: Double = 2.0
    private let fftMailbox = FFTFrameMailbox()
    private var dspFFTHandler: (([Float], Int) -> Void)?
    private var networkPoorStreak: Int = 0
    private var networkGoodStreak: Int = 0
    private var audioPoorStreak: Int = 0
    private var audioGoodStreak: Int = 0
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
    private var shouldStartListeningOnConnect: Bool = false
    private var connectTrace: PerformanceTrace?
    private var firstAudioTrace: PerformanceTrace?
    private var pendingRetuneTrace: PerformanceTrace?
    private var lastSevereAudioUnderrunAt: CFAbsoluteTime = 0
    private var profileSwitchTask: Task<Void, Never>?

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
        audioEngine.onFirstAudioFrame = { [weak self] in
            self?.handleFirstAudioFrame()
        }

        connection.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionStateChange(state)
            }
        }

        // Create Metal renderer
        if let device = MTLCreateSystemDefaultDevice() {
            waterfallRenderer = WaterfallRenderer(device: device)
            waterfallRenderer?.setRenderingActive(false)
        }
        dspPipeline.setFFTFrameRate(effectiveUIFPS)
        waterfallRenderer?.targetFPS = 60 // Default high for smooth motion
        waterfallRenderer?.expectedDataInterval = 1.0 / Double(effectiveUIFPS)
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
        updateTelemetryContext()
    }

    @MainActor deinit {
        cancelConnectTrace()
        cancelFirstAudioTrace()
        cancelPendingRetuneTrace()
        connection.onStateChange = nil
        audioEngine.onFirstAudioFrame = nil
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
        startConnectTrace()
        connection.connect(host: host, port: port)
        updateDiagnosticsTimerState()
    }

    func autoConnectIfConfigured(host: String, port: UInt16) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }

        switch connection.state {
        case .disconnected, .failed:
            SDRDebug.print("📻 autoConnect to \(trimmedHost):\(port)")
            connect(host: trimmedHost, port: port)
        case .connecting, .validatingHeader, .connected, .reconnecting:
            break
        }
    }

    func disconnect() {
        shouldStartListeningOnConnect = false
        cancelConnectTrace()
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
        guard !isPlaying else { return }
        SDRDebug.print("📻 startListening called, connection.state=\(connection.state)")
        guard case .connected = connection.state else {
            SDRDebug.print("📻 startListening: NOT connected, aborting")
            return
        }
        SDRDebug.print("📻 startListening: connected, proceeding")
        shouldStartListeningOnConnect = false
        beginFirstAudioTrace()

        // Send initial commands
        applyDirectSamplingForCurrentFrequency()
        applyOffsetTuningIfSupported()
        applyBiasTeeIfSupported()
        applyPerformancePolicy()
        connection.setSampleRate(dspPipeline.sampleRate)
        applyReceiverTuning()
        connection.setGainMode(gainMode)
        connection.setAGCMode(gainMode == .auto)
        if gainMode == .manual {
            connection.setGain(gainTenthsCommandValue(from: gainValue))
        }
        if ppm != 0 {
            connection.setPPM(ppmCommandValue(from: ppm))
        }

        // Configure DSP
        dspPipeline.mode = mode
        dspPipeline.bandwidthHz = bandwidthHz
        dspPipeline.bfoOffsetHz = bfoOffset
        dspPipeline.setSquelch(squelchThreshold(for: squelchLevel))

        // Start audio
        do {
            try audioEngine.configureSession()
            audioEngine.armAudioSignalEvent()
            try audioEngine.start()
        } catch {
            SDRLogger.audio.error("Failed to start audio: \(error)")
            TelemetryService.shared.recordNonFatal(
                kind: "audio_start_failed",
                message: error.localizedDescription,
                metadata: [
                    "mode": mode.rawValue,
                    "sample_rate": String(dspPipeline.sampleRate)
                ]
            )
            cancelFirstAudioTrace()
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
        updateTelemetryContext()
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
        shouldStartListeningOnConnect = false
        cancelFirstAudioTrace()
        cancelPendingRetuneTrace()
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

    func requestStartListeningWhenConnected() {
        shouldStartListeningOnConnect = true
        if case .connected = connection.state {
            startListening()
        }
    }

    func cancelPendingStartListening() {
        shouldStartListeningOnConnect = false
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
        let sanitizedHz = min(maxTunableFrequencyHz, max(1_000, hz))
        let didChangeFrequency = sanitizedHz != frequencyHz
        frequencyHz = sanitizedHz
        guard didChangeFrequency else {
            updateNowPlaying()
            updateTelemetryContext()
            return
        }

        let applyRetune = {
            self.applyDirectSamplingForCurrentFrequency()
            self.applyOffsetTuningIfSupported()
            self.applyReceiverTuning()
            self.iqBuffer.flush()
            self.audioBuffer.flush()
            self.dspPipeline.resetState()
        }

        if isPlaying, didChangeFrequency {
            audioEngine.performClickFreeTransition {
                self.beginRetuneTrace(reason: "frequency")
                applyRetune()
            }
        } else {
            applyRetune()
        }
        updateNowPlaying()
        updateTelemetryContext()
    }

    func stepFrequency(up: Bool) {
        let newFreq = up ? frequencyHz + stepHz : frequencyHz - stepHz
        setFrequency(newFreq)
    }

    func setMode(_ newMode: DemodMode) {
        let didChangeMode = newMode != mode
        mode = newMode
        stepHz = newMode.defaultStepHz
        bandwidthHz = newMode.defaultBandwidthHz
        guard didChangeMode else {
            updateNowPlaying()
            updateTelemetryContext()
            return
        }

        let applyModeChange = {
            self.dspPipeline.mode = newMode
            self.dspPipeline.bandwidthHz = self.bandwidthHz
            self.dspPipeline.resetState()
            self.audioBuffer.flush()
        }

        if isPlaying, didChangeMode {
            audioEngine.performClickFreeTransition {
                self.beginRetuneTrace(reason: "mode")
                applyModeChange()
            }
        } else {
            applyModeChange()
        }
        applyPerformancePolicy()
        updateNowPlaying()
        updateTelemetryContext()
    }

    func setBandwidth(_ hz: Int) {
        guard bandwidthHz != hz else { return }
        bandwidthHz = hz
        dspPipeline.bandwidthHz = hz
    }

    func setGain(mode: GainMode, value: Float) {
        self.gainMode = mode
        self.gainValue = value
        connection.setGainMode(mode)
        connection.setAGCMode(mode == .auto)
        if mode == .manual {
            connection.setGain(gainTenthsCommandValue(from: value))
        }
    }

    func setPPM(_ value: Float) {
        ppm = value
        connection.setPPM(ppmCommandValue(from: value))
    }

    func setDirectSamplingPreference(_ preference: DirectSamplingPreference) {
        directSamplingPreference = preference
        applyDirectSamplingForCurrentFrequency()
        retuneForRFControlChange()
    }

    func setOffsetTuningEnabled(_ enabled: Bool) {
        isOffsetTuningEnabled = enabled
        applyOffsetTuningIfSupported()
        retuneForRFControlChange()
    }

    func setBiasTeeEnabled(_ enabled: Bool) {
        isBiasTeeEnabled = enabled
        applyBiasTeeIfSupported()
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

        // Debounce: only apply after rapid switching settles (300ms).
        // This avoids multiple back-to-back DSP rebuilds, settle windows,
        // and main-thread-blocking transitions when the user rapidly taps profiles.
        profileSwitchTask?.cancel()
        profileSwitchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.applyPerformancePolicy()
            self.updateTelemetryContext()
        }
    }

    func applyWaterfallColorScheme(_ schemeName: String) {
        waterfallRenderer?.setColorScheme(named: schemeName)
    }

    func applyDeemphasis(_ microseconds: Int) {
        dspPipeline.setDeemphasisUs(microseconds)
    }

    func applyRFControls(
        directSamplingPreference: DirectSamplingPreference,
        offsetTuningEnabled: Bool,
        biasTeeEnabled: Bool
    ) {
        self.directSamplingPreference = directSamplingPreference
        self.isOffsetTuningEnabled = offsetTuningEnabled
        self.isBiasTeeEnabled = biasTeeEnabled
        applyDirectSamplingForCurrentFrequency()
        applyOffsetTuningIfSupported()
        applyBiasTeeIfSupported()
        retuneForRFControlChange()
    }

    func setAudioToneFilters(highPassHz: Int, lowPassHz: Int) {
        let normalized = normalizedAudioFilterCutoffs(
            highPassHz: highPassHz,
            lowPassHz: lowPassHz
        )
        audioHighPassHz = normalized.highPass
        audioLowPassHz = normalized.lowPass
        dspPipeline.setAudioToneFilters(
            highPassHz: normalized.highPass,
            lowPassHz: normalized.lowPass
        )
    }

    func setNoiseBlankerThreshold(_ threshold: Float) {
        noiseBlankerThreshold = threshold
        dspPipeline.setNoiseBlankerThreshold(threshold)
    }

    func setAudioAgcEnabled(_ enabled: Bool) {
        audioAgcEnabled = enabled
        dspPipeline.audioAgcEnabled = enabled
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
                let audioBufferDurationSec = Double(self.audioBuffer.capacitySamples) / 48_000.0
                self.audioHeadroomMs = self.audioBufferFill * audioBufferDurationSec * 1000.0
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
        // Ensure renderer target FPS is high enough for smooth interpolation, even on Ultra Low.
        waterfallRenderer?.targetFPS = max(targetFPS, lowPower ? 30 : 60)
        // Use fixed data interval for interpolation (e.g. 1/12s) to hide jitter.
        waterfallRenderer?.expectedDataInterval = 1.0 / Double(targetFPS)

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

        let targetSampleRate = max(minimumSampleRate(for: mode), min(preferredSampleRate, sampleRateCap))
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
        var buffersFlushedInsideSampleRateTransition = false
        if effectiveSampleRate != targetSampleRate {
            effectiveSampleRate = targetSampleRate
            if isPlaying {
                audioEngine.performClickFreeTransition {
                    self.beginRetuneTrace(reason: "sample_rate")
                    self.dspPipeline.setSampleRate(targetSampleRate)
                    if case .connected = self.connection.state {
                        self.connection.setSampleRate(targetSampleRate)
                        self.applyReceiverTuning()
                    }
                    self.iqBuffer.flush()
                    self.audioBuffer.flush()
                }
                buffersFlushedInsideSampleRateTransition = true
            } else {
                dspPipeline.setSampleRate(targetSampleRate)
                if case .connected = connection.state {
                    connection.setSampleRate(targetSampleRate)
                    applyReceiverTuning()
                }
            }
            dspConfigChanged = true
        }

        if effectiveFFTSize != targetFFTSize {
            effectiveFFTSize = targetFFTSize
            dspPipeline.setFFTSize(targetFFTSize)
            dspConfigChanged = true
        }

        if dspConfigChanged, isPlaying, !buffersFlushedInsideSampleRateTransition {
            iqBuffer.flush()
            audioBuffer.flush()
        }

        if dspConfigChanged {
            fftMailbox.clear()
            lastWaterfallRow.removeAll(keepingCapacity: true)
            spectrumProcessor.reset()
            waterfallRenderer?.clearWaterfall()
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
            let visibleBins = zoomSlice(normalized)
            waterfallRenderer?.addWaterfallRow(visibleBins)
            waterfallRenderer?.updateSpectrumBins(visibleBins)
            if lastWaterfallRow.count != visibleBins.count {
                lastWaterfallRow = visibleBins
            } else {
                lastWaterfallRow.withUnsafeMutableBufferPointer { dst in
                    visibleBins.withUnsafeBufferPointer { src in
                        dst.baseAddress!.update(from: src.baseAddress!, count: visibleBins.count)
                    }
                }
            }
        }
    }

    /// Extract the center portion of bins based on current zoom level.
    private func zoomSlice(_ bins: [Float]) -> [Float] {
        guard waterfallZoom > 1.0, !bins.isEmpty else { return bins }
        let visibleCount = max(2, Int(Double(bins.count) / waterfallZoom))
        let start = (bins.count - visibleCount) / 2
        return Array(bins[start..<(start + visibleCount)])
    }

    func setWaterfallZoom(_ zoom: Double) {
        waterfallZoom = min(8.0, max(1.0, zoom))
    }

    // MARK: - Helpers

    private func desiredDirectSamplingMode(for frequencyHz: Int) -> DirectSamplingMode {
        switch directSamplingPreference {
        case .off:
            return .off
        case .iBranch:
            return supportsManualDirectSampling ? .iBranch : .off
        case .qBranch:
            return supportsManualDirectSampling ? .qBranch : .off
        case .auto:
            guard supportsDirectSamplingAuto else { return .off }
            return frequencyHz < directSamplingThresholdHz ? .qBranch : .off
        }
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

    private func gainTenthsCommandValue(from gainDb: Float) -> Int {
        let rounded = Int((gainDb * 10).rounded())
        return max(0, min(Int(UInt32.max), rounded))
    }

    private func ppmCommandValue(from ppm: Float) -> Int32 {
        Int32(clamping: Int(ppm.rounded()))
    }

    private func applyDirectSamplingForCurrentFrequency() {
        let mode = desiredDirectSamplingMode(for: frequencyHz)
        directSamplingMode = mode
        isDirectSamplingActive = mode != .off
        connection.setDirectSampling(mode)
    }

    private func applyOffsetTuningIfSupported() {
        connection.setOffsetTuning(supportsOffsetTuning && isOffsetTuningEnabled)
    }

    private func applyReceiverTuning() {
        let plan = ReceiverTuningPlan.make(
            requestedFrequencyHz: frequencyHz,
            sampleRateHz: dspPipeline.sampleRate,
            supportsHardwareOffsetTuning: supportsOffsetTuning,
            hardwareOffsetTuningEnabled: isOffsetTuningEnabled,
            directSamplingActive: isDirectSamplingActive,
            maximumFrequencyHz: maxTunableFrequencyHz
        )
        dspPipeline.softwareFrequencyShiftHz = Float(plan.softwareFrequencyShiftHz)
        connection.setFrequency(plan.tunerFrequencyHz)
    }

    private func retuneForRFControlChange() {
        let applyRetune = {
            self.applyReceiverTuning()
            self.iqBuffer.flush()
            self.audioBuffer.flush()
            self.dspPipeline.resetState()
        }

        if isPlaying {
            audioEngine.performClickFreeTransition {
                self.beginRetuneTrace(reason: "rf_control")
                applyRetune()
            }
        } else {
            applyReceiverTuning()
        }
    }

    private func minimumSampleRate(for mode: DemodMode) -> Int {
        switch mode {
        case .wfm:
            return minimumWFMSampleRateHz
        default:
            return minimumSampleRateHz
        }
    }

    private func applyBiasTeeIfSupported() {
        connection.setBiasTee(supportsBiasTee && isBiasTeeEnabled)
    }

    private func normalizedAudioFilterCutoffs(highPassHz: Int, lowPassHz: Int) -> (highPass: Int, lowPass: Int) {
        let requestedHP = max(0, highPassHz)
        let requestedLP = max(0, lowPassHz)

        let clampedLP = requestedLP > 0 ? min(maxAudioFilterCutoffHz, requestedLP) : 0
        let maxHP = clampedLP > 0 ? max(0, clampedLP - minAudioFilterGapHz) : maxAudioFilterCutoffHz
        let clampedHP = min(requestedHP, maxHP)

        return (clampedHP, clampedLP)
    }

    private func updateNetworkQuality() {
        guard isPlaying else {
            resetNetworkQualityState(hint: "Idle")
            return
        }

        let iqUnderruns = iqBuffer.underrunCount
        let audioUnderruns = audioBuffer.underrunCount
        let hadIQUnderrun = iqUnderruns > lastIQUnderrunCount
        let hadAudioUnderrun = audioUnderruns > lastAudioUnderrunCount
        lastIQUnderrunCount = iqUnderruns
        lastAudioUnderrunCount = audioUnderruns

        let expectedThroughputBytes = Double(dspPipeline.sampleRate) * iqBytesPerSamplePair
        let lowThroughputWarning = connection.throughputBytesPerSec < expectedThroughputBytes * 0.85
        let lowThroughputCritical = connection.throughputBytesPerSec < expectedThroughputBytes * 0.70
        let lowIQBufferWarning = iqBufferFill < 0.15
        let lowIQBufferCritical = iqBufferFill < 0.07

        let lowAudioHeadroomWarning = audioHeadroomMs < 120
        let lowAudioHeadroomCritical = audioHeadroomMs < 50

        var networkIssueHint: String?
        if hadIQUnderrun {
            networkIssueHint = "IQ underruns"
        } else if lowThroughputCritical {
            networkIssueHint = "Low TCP throughput"
        } else if lowThroughputWarning && lowIQBufferCritical {
            networkIssueHint = "Low throughput + thin IQ buffer"
        } else if lowThroughputWarning && lowIQBufferWarning {
            networkIssueHint = "IQ buffer draining"
        }

        var audioIssueHint: String?
        if hadAudioUnderrun {
            audioIssueHint = "Audio underruns"
        } else if lowAudioHeadroomCritical {
            audioIssueHint = "Audio headroom critically low"
        } else if lowAudioHeadroomWarning {
            audioIssueHint = "Audio buffer low"
        }

        if let networkIssueHint {
            networkPoorStreak += 1
            networkGoodStreak = 0
            if networkPoorStreak >= 3 {
                isNetworkPoor = true
            }
            networkQualityHint = networkIssueHint
        } else {
            networkGoodStreak += 1
            networkPoorStreak = 0
            if networkGoodStreak >= 4 {
                isNetworkPoor = false
            }
        }

        if let audioIssueHint {
            audioPoorStreak += 1
            audioGoodStreak = 0
            if audioPoorStreak >= 2 {
                isAudioStarving = true
            }
            if networkIssueHint == nil {
                networkQualityHint = audioIssueHint
            }
        } else {
            audioGoodStreak += 1
            audioPoorStreak = 0
            if audioGoodStreak >= 4 {
                isAudioStarving = false
            }
        }

        if !isNetworkPoor && !isAudioStarving {
            if networkGoodStreak >= 2 && audioGoodStreak >= 2 {
                networkQualityHint = "Good"
            }
        }

        if hadAudioUnderrun && lowAudioHeadroomCritical {
            reportSevereAudioUnderrunIfNeeded()
        }
    }

    private func resetNetworkQualityState(hint: String) {
        isNetworkPoor = false
        isAudioStarving = false
        networkQualityHint = hint
        networkPoorStreak = 0
        networkGoodStreak = 0
        audioPoorStreak = 0
        audioGoodStreak = 0
        lastIQUnderrunCount = iqBuffer.underrunCount
        lastAudioUnderrunCount = audioBuffer.underrunCount
    }

    private func sampleProfile(for label: String) -> (sampleRate: Int, fftSize: Int, uiFps: Int) {
        switch label {
        case "HF+ Low":
            return (192_000, 1024, 12)
        case "Ultra Low":
            return (250_000, 1024, 12)
        case "HF+ High":
            return (768_000, 2048, 20)
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

    private func handleConnectionStateChange(_ newState: ConnectionState) {
        connectionState = newState
        if case .connected(let header) = newState {
            isConnected = true
            let capabilities = header.tunerType.capabilities
            supportsDirectSamplingAuto = capabilities.supportsDirectSamplingAuto
            supportsManualDirectSampling = capabilities.supportsManualDirectSampling
            supportsOffsetTuning = capabilities.supportsOffsetTuning
            supportsBiasTee = capabilities.supportsBiasTeeControl
            if !supportsManualDirectSampling {
                directSamplingPreference = .auto
            }
            if !supportsOffsetTuning {
                isOffsetTuningEnabled = false
            }
            if !supportsBiasTee {
                isBiasTeeEnabled = false
            }

            applyDirectSamplingForCurrentFrequency()
            applyOffsetTuningIfSupported()
            applyBiasTeeIfSupported()
            completeConnectTrace()

            if shouldStartListeningOnConnect {
                shouldStartListeningOnConnect = false
                startListening()
            }
        } else {
            isConnected = false
            isDirectSamplingActive = false
            directSamplingMode = .off
            if case .disconnected = newState {
                cancelConnectTrace()
            }
        }

        if case .failed(let message) = newState {
            cancelConnectTrace()
            TelemetryService.shared.recordNonFatal(
                kind: "network_connection_failed",
                message: message,
                metadata: ["state": "failed"]
            )
        }
        updateDiagnosticsTimerState()
    }

    private func handleFirstAudioFrame() {
        completeFirstAudioTrace()
        completePendingRetuneTrace()
    }

    private func startConnectTrace() {
        cancelConnectTrace()
        connectTrace = PerformanceTrace(
            name: .connectLatency,
            metadata: ["protocol": SDRProtocol.rtlTcp.rawValue]
        )
        connectTrace?.start()
    }

    private func beginFirstAudioTrace() {
        cancelFirstAudioTrace()
        firstAudioTrace = PerformanceTrace(
            name: .firstAudioLatency,
            metadata: [
                "mode": mode.rawValue,
                "sample_rate": String(dspPipeline.sampleRate)
            ]
        )
        firstAudioTrace?.start()
    }

    private func beginRetuneTrace(reason: String) {
        cancelPendingRetuneTrace()
        pendingRetuneTrace = PerformanceTrace(
            name: .retuneLatency,
            metadata: [
                "reason": reason,
                "mode": mode.rawValue,
                "sample_rate": String(dspPipeline.sampleRate)
            ]
        )
        pendingRetuneTrace?.start()
        audioEngine.armAudioSignalEvent()
    }

    private func completeConnectTrace() {
        connectTrace?.stop()
        connectTrace = nil
    }

    private func cancelConnectTrace() {
        connectTrace?.cancel()
        connectTrace = nil
    }

    private func completeFirstAudioTrace() {
        firstAudioTrace?.stop()
        firstAudioTrace = nil
    }

    private func cancelFirstAudioTrace() {
        firstAudioTrace?.cancel()
        firstAudioTrace = nil
    }

    private func completePendingRetuneTrace() {
        pendingRetuneTrace?.stop()
        pendingRetuneTrace = nil
    }

    private func cancelPendingRetuneTrace() {
        pendingRetuneTrace?.cancel()
        pendingRetuneTrace = nil
    }

    private func updateTelemetryContext() {
        TelemetryService.shared.updateRuntimeContext(
            mode: mode,
            sampleRate: dspPipeline.sampleRate,
            protocolType: .rtlTcp
        )
    }

    private func reportSevereAudioUnderrunIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSevereAudioUnderrunAt >= 30 else { return }
        lastSevereAudioUnderrunAt = now
        TelemetryService.shared.recordNonFatal(
            kind: "audio_underrun_severe",
            message: "Audio underrun with critically low headroom",
            metadata: [
                "audio_headroom_ms": String(format: "%.1f", audioHeadroomMs),
                "audio_fill_pct": String(format: "%.1f", audioBufferFill * 100),
                "mode": mode.rawValue,
                "sample_rate": String(dspPipeline.sampleRate)
            ]
        )
    }
}
