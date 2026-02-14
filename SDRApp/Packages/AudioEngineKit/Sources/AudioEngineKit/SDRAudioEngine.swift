import AVFoundation
import MediaPlayer
import Observation
import SDRSupport

/// Manages AVAudioEngine playback from the AudioRingBuffer.
/// Handles audio session, lock screen controls, background playback, and interruptions.
@Observable
public final class SDRAudioEngine: @unchecked Sendable {
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
    private let preferredIOBufferDuration: TimeInterval = 0.02
    private var isInterrupted: Bool = false
    private var shouldResumeAfterInterruption: Bool = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var remoteCommandsConfigured: Bool = false

    // Callbacks for lock screen remote commands
    public var onPlayPause: (() -> Void)?
    public var onNextStation: (() -> Void)?
    public var onPreviousStation: (() -> Void)?

    public init(audioBuffer: AudioRingBuffer) {
        self.audioBuffer = audioBuffer
    }

    deinit {
        removeObservers()
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

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            SDRLogger.audio.error("Failed to create AVAudioFormat")
            return
        }

        let buffer = self.audioBuffer
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let dest = ablPointer.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_InvalidParameter
            }

            let destBuf = UnsafeMutableBufferPointer(start: dest, count: Int(frameCount))
            _ = buffer.read(into: destBuf, count: Int(frameCount))

            return noErr
        }

        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume

        try engine.start()
        isPlaying = true
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
