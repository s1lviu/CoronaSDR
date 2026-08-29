import AVFoundation
import MediaPlayer
import Observation
import Dispatch
import SDRSupport
#if canImport(UIKit)
import UIKit
#endif

/// Manages AVAudioEngine playback from the AudioRingBuffer.
/// Handles audio session, lock screen controls, background playback, and interruptions.
@Observable
public final class SDRAudioEngine: @unchecked Sendable {
    private enum TransitionPhase: Equatable {
        case idle
        case fadingOut
        case mutedWaitingForData
        case fadingIn
    }

    public var isPlaying: Bool = false
    public var volume: Float = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    // Now Playing info
    public var nowPlayingTitle: String = "CoronaSDR" {
        didSet { updateNowPlaying() }
    }
    public var nowPlayingSubtitle: String = "" {
        didSet { updateNowPlaying() }
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let audioBuffer: AudioRingBuffer
    private let sampleRate: Double = 48000
    private let channelCount: AVAudioChannelCount = 2
    private let preferredIOBufferDuration: TimeInterval = 0.02
    private let renderScratchCapacityFrames: Int = 65_536
    private let renderScratch: UnsafeMutableBufferPointer<Float>
    private var isInterrupted: Bool = false
    private var shouldResumeAfterInterruption: Bool = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var remoteCommandsConfigured: Bool = false
    @ObservationIgnored private let nowPlayingArtwork: MPMediaItemArtwork?
    private let audioSignalLock = NSLock()
    private var isAudioSignalEventArmed = false
    private let transitionExecutionLock = NSLock()
    private let transitionStateLock = NSLock()
    private let transitionFadeDurationMs: Double = 5.0
    private let transitionFadeTimeoutMs: Int = 250
    private var transitionPhase: TransitionPhase = .idle
    private var transitionFadeOutRemainingSamples: Int = 0
    private var transitionFadeInRemainingSamples: Int = 0
    private var transitionFadeOutSemaphore: DispatchSemaphore?
    private var suppressAudioSignalEvents: Bool = false

    // Callbacks for lock screen remote commands
    public var onPlayPause: (() -> Void)?
    public var onNextStation: (() -> Void)?
    public var onPreviousStation: (() -> Void)?
    public var onFirstAudioFrame: (() -> Void)?

    public init(audioBuffer: AudioRingBuffer) {
        self.audioBuffer = audioBuffer
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: renderScratchCapacityFrames * Int(channelCount))
        scratch.initialize(repeating: 0, count: renderScratchCapacityFrames * Int(channelCount))
        self.renderScratch = UnsafeMutableBufferPointer(
            start: scratch,
            count: renderScratchCapacityFrames * Int(channelCount)
        )
        self.nowPlayingArtwork = Self.loadNowPlayingArtwork()
    }

    deinit {
        removeObservers()
        renderScratch.baseAddress?.deinitialize(count: renderScratch.count)
        renderScratch.baseAddress?.deallocate()
    }

    /// Configure audio session for playback.
    public func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredSampleRate(sampleRate)
        // Higher IO duration is a standard trade-off for lower CPU/wakeup load in streaming apps.
        try session.setPreferredIOBufferDuration(preferredIOBufferDuration)
        try session.setActive(true)

        setupInterruptionHandling()
        setupRouteChangeHandling()
        setupMediaServicesResetHandling()
        setupRemoteCommands()

        SDRLogger.audio.info("Audio session configured: rate=\(session.sampleRate), bufferDuration=\(session.ioBufferDuration)")
    }

    /// Start audio playback.
    public func start() throws {
        guard !isPlaying else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            SDRLogger.audio.error("Failed to create AVAudioFormat")
            return
        }

        let buffer = self.audioBuffer
        let channels = Int(channelCount)
        let scratch = renderScratch
        let scratchCapacityFrames = renderScratchCapacityFrames
        let onAudioSignal: () -> Void = { [weak self] in
            self?.consumeAudioSignalArmIfNeeded()
        }
        let applyTransitionEnvelope: (UnsafeMutableBufferPointer<Float>, Int) -> Bool = { [weak self] samples, validCount in
            self?.applyTransitionEnvelope(to: samples, validSampleCount: validCount) ?? true
        }
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            let requestedSamples = frames * channels

            let actual: Int
            let shouldNotifyAudioSignal: Bool

            if ablPointer.count == 1,
               let dest = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) {
                let destBuf = UnsafeMutableBufferPointer(start: dest, count: requestedSamples)
                actual = buffer.read(into: destBuf, count: requestedSamples)
                shouldNotifyAudioSignal = applyTransitionEnvelope(destBuf, actual)
            } else {
                guard frames <= scratchCapacityFrames else {
                    for audioBuffer in ablPointer {
                        if let dest = audioBuffer.mData?.assumingMemoryBound(to: Float.self) {
                            UnsafeMutableBufferPointer(start: dest, count: frames).initialize(repeating: 0)
                        }
                    }
                    return noErr
                }

                let scratchBuf = UnsafeMutableBufferPointer(start: scratch.baseAddress!, count: requestedSamples)
                actual = buffer.read(into: scratchBuf, count: requestedSamples)
                shouldNotifyAudioSignal = applyTransitionEnvelope(scratchBuf, actual)

                for channel in 0..<min(channels, ablPointer.count) {
                    guard let dest = ablPointer[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for frame in 0..<frames {
                        dest[frame] = scratchBuf[frame * channels + channel]
                    }
                }
            }

            if actual > 0, shouldNotifyAudioSignal {
                onAudioSignal()
            }

            return noErr
        }

        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume

        try engine.start()
        isPlaying = true
        resetTransitionState()
        armAudioSignalEvent()
        updateNowPlaying()

        SDRLogger.audio.info("Audio engine started")
    }

    /// Stop audio playback.
    public func stop() {
        guard isPlaying || sourceNode != nil else { return }

        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        isPlaying = false
        audioSignalLock.lock()
        isAudioSignalEventArmed = false
        audioSignalLock.unlock()
        resetTransitionState()
        clearNowPlaying()

        SDRLogger.audio.info("Audio engine stopped")
    }

    // MARK: - Interruption Handling

    private func setupInterruptionHandling() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                SDRLogger.audio.info("Audio interruption began")
                self.isInterrupted = true
                self.shouldResumeAfterInterruption = self.isPlaying
                if self.isPlaying {
                    self.engine.pause()
                    self.isPlaying = false
                    self.updateNowPlaying()
                }
            case .ended:
                SDRLogger.audio.info("Audio interruption ended")
                self.isInterrupted = false
                let optionsValue = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                self.resumeAfterInterruptionIfNeeded(options: options)
            @unknown default:
                break
            }
        }
    }

    private func setupRouteChangeHandling() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

            SDRLogger.audio.info("Audio route changed: \(reason.rawValue)")

            if reason == .oldDeviceUnavailable {
                // Headphones unplugged etc - keep playing through speaker
                if self?.isPlaying == true {
                    try? self?.engine.start()
                }
            }
        }
    }

    private func setupMediaServicesResetHandling() {
        guard mediaServicesResetObserver == nil else { return }
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let shouldResume = self.isPlaying || self.shouldResumeAfterInterruption
            do {
                try self.configureSession()
                if shouldResume, self.sourceNode != nil {
                    try self.engine.start()
                    self.isPlaying = true
                    self.updateNowPlaying()
                }
                SDRLogger.audio.info("Audio media services were reset and session was reconfigured")
            } catch {
                SDRLogger.audio.error("Failed to recover after media services reset: \(error)")
            }
        }
    }

    // MARK: - Remote Commands (Lock Screen)

    private func setupRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        _ = center.playCommand.addTarget { [weak self] _ in
            self?.onPlayPause?()
            return .success
        }

        center.pauseCommand.isEnabled = true
        _ = center.pauseCommand.addTarget { [weak self] _ in
            self?.onPlayPause?()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        _ = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onPlayPause?()
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        _ = center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNextStation?()
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        _ = center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPreviousStation?()
            return .success
        }
    }

    private func resumeAfterInterruptionIfNeeded(options: AVAudioSession.InterruptionOptions) {
        let shouldResume = shouldResumeAfterInterruption || options.contains(.shouldResume)
        shouldResumeAfterInterruption = false
        guard shouldResume else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            if sourceNode != nil {
                try engine.start()
                isPlaying = true
                updateNowPlaying()
            }
        } catch {
            SDRLogger.audio.error("Failed to resume audio after interruption: \(error)")
        }
    }

    private func removeObservers() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        if let mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(mediaServicesResetObserver)
            self.mediaServicesResetObserver = nil
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: nowPlayingSubtitle,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Arms a one-shot callback that fires when the next non-silent render callback pulls samples.
    public func armAudioSignalEvent() {
        audioSignalLock.lock()
        isAudioSignalEventArmed = true
        audioSignalLock.unlock()
    }

    /// Executes a disruptive audio-path transition without clicks:
    /// fade-out -> transition closure while muted -> fade-in on first resumed audio samples.
    public func performClickFreeTransition(_ transition: () -> Void) {
        transitionExecutionLock.lock()
        defer { transitionExecutionLock.unlock() }

        guard isPlaying else {
            transition()
            return
        }

        let fadeOutSemaphore = DispatchSemaphore(value: 0)
        transitionStateLock.lock()
        transitionPhase = .fadingOut
        transitionFadeOutRemainingSamples = transitionFadeSamples
        transitionFadeInRemainingSamples = transitionFadeSamples
        transitionFadeOutSemaphore = fadeOutSemaphore
        suppressAudioSignalEvents = true
        transitionStateLock.unlock()

        let timeout = DispatchTime.now() + .milliseconds(transitionFadeTimeoutMs)
        let waitResult = fadeOutSemaphore.wait(timeout: timeout)
        if waitResult == .timedOut {
            SDRLogger.audio.warning("Audio transition fade-out timed out after \(self.transitionFadeTimeoutMs)ms")
        }

        transition()

        transitionStateLock.lock()
        transitionPhase = .mutedWaitingForData
        transitionFadeOutSemaphore = nil
        suppressAudioSignalEvents = false
        transitionStateLock.unlock()
    }

    private var transitionFadeSamples: Int {
        max(1, AudioFade.fadeSamples(durationMs: transitionFadeDurationMs, sampleRate: sampleRate) * Int(channelCount))
    }

    private func resetTransitionState() {
        transitionStateLock.lock()
        transitionPhase = .idle
        transitionFadeOutRemainingSamples = 0
        transitionFadeInRemainingSamples = 0
        transitionFadeOutSemaphore = nil
        suppressAudioSignalEvents = false
        transitionStateLock.unlock()
    }

    private func applyTransitionEnvelope(
        to buffer: UnsafeMutableBufferPointer<Float>,
        validSampleCount: Int
    ) -> Bool {
        let totalCount = buffer.count
        guard totalCount > 0 else { return true }

        let validCount = max(0, min(validSampleCount, totalCount))
        let fadeSamples = transitionFadeSamples
        var shouldNotifyAudioSignal = true
        var semaphoreToSignal: DispatchSemaphore?

        transitionStateLock.lock()
        shouldNotifyAudioSignal = !suppressAudioSignalEvents

        var phase = transitionPhase
        var fadeOutRemaining = transitionFadeOutRemainingSamples
        var fadeInRemaining = transitionFadeInRemainingSamples

        if phase == .mutedWaitingForData, validCount > 0 {
            phase = .fadingIn
            fadeInRemaining = fadeSamples
        }

        if phase != .idle {
            for idx in 0..<totalCount {
                switch phase {
                case .idle:
                    break

                case .fadingOut:
                    let gain = max(0, min(1, Float(fadeOutRemaining) / Float(fadeSamples)))
                    if idx < validCount {
                        buffer[idx] *= gain
                    } else {
                        buffer[idx] = 0
                    }

                    fadeOutRemaining -= 1
                    if fadeOutRemaining <= 0 {
                        phase = .mutedWaitingForData
                        buffer[idx] = 0
                        if semaphoreToSignal == nil {
                            semaphoreToSignal = transitionFadeOutSemaphore
                        }
                    }

                case .mutedWaitingForData:
                    buffer[idx] = 0

                case .fadingIn:
                    if idx < validCount {
                        let progressed = fadeSamples - fadeInRemaining
                        let gain = max(0, min(1, Float(progressed) / Float(fadeSamples)))
                        buffer[idx] *= gain
                        fadeInRemaining -= 1
                        if fadeInRemaining <= 0 {
                            phase = .idle
                        }
                    } else {
                        buffer[idx] = 0
                    }
                }
            }
        }

        transitionPhase = phase
        transitionFadeOutRemainingSamples = max(0, fadeOutRemaining)
        transitionFadeInRemainingSamples = max(0, fadeInRemaining)
        if semaphoreToSignal != nil {
            transitionFadeOutSemaphore = nil
        }
        if phase == .idle {
            suppressAudioSignalEvents = false
        }
        transitionStateLock.unlock()

        semaphoreToSignal?.signal()
        return shouldNotifyAudioSignal
    }

    private func consumeAudioSignalArmIfNeeded() {
        var shouldFire = false
        audioSignalLock.lock()
        if isAudioSignalEventArmed {
            isAudioSignalEventArmed = false
            shouldFire = true
        }
        audioSignalLock.unlock()

        guard shouldFire else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFirstAudioFrame?()
        }
    }

    private static func loadNowPlayingArtwork() -> MPMediaItemArtwork? {
        #if canImport(UIKit)
        let iconNames = [
            "AppIcon60x60@3x",
            "AppIcon60x60@2x",
            "AppIcon76x76@2x",
            "AppIcon83.5x83.5@2x",
            "AppIcon60x60"
        ]

        for name in iconNames {
            if let image = UIImage(named: name, in: .main, compatibleWith: nil) {
                return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = UIImage(contentsOfFile: url.path) {
                return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }
        #endif
        return nil
    }
}
