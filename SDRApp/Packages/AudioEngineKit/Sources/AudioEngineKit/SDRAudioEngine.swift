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
    public var nowPlayingTitle: String = "SDR Radio" {
        didSet { updateNowPlaying() }
    }
    public var nowPlayingSubtitle: String = "" {
        didSet { updateNowPlaying() }
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let audioBuffer: AudioRingBuffer
    private let sampleRate: Double = 48000
    private var isInterrupted: Bool = false

    // Callbacks for lock screen remote commands
    public var onPlayPause: (() -> Void)?
    public var onNextStation: (() -> Void)?
    public var onPreviousStation: (() -> Void)?

    public init(audioBuffer: AudioRingBuffer) {
        self.audioBuffer = audioBuffer
    }

    /// Configure audio session for playback.
    public func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.005) // 5ms buffer
        try session.setActive(true)

        setupInterruptionHandling()
        setupRouteChangeHandling()
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
        guard isPlaying else { return }

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
        _ = NotificationCenter.default.addObserver(
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
            case .ended:
                SDRLogger.audio.info("Audio interruption ended")
                self.isInterrupted = false
                if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        try? self.engine.start()
                        self.isPlaying = true
                    }
                }
            @unknown default:
                break
            }
        }
    }

    private func setupRouteChangeHandling() {
        _ = NotificationCenter.default.addObserver(
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

    // MARK: - Remote Commands (Lock Screen)

    private func setupRemoteCommands() {
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
