import XCTest
@testable import AudioEngineKit

@MainActor
final class AudioPlaybackControlTests: XCTestCase {
    func testRepeatedPlayDoesNotPausePlayback() {
        let engine = makeEngine()
        var playing = false
        engine.onPlay = { playing = true }
        engine.onPause = { playing = false }
        engine.onPlayPause = { playing.toggle() }

        engine.handleRemoteCommand(.play)
        engine.handleRemoteCommand(.play)

        XCTAssertTrue(playing)
    }

    func testRepeatedPauseDoesNotStartPlayback() {
        let engine = makeEngine()
        var playing = true
        engine.onPlay = { playing = true }
        engine.onPause = { playing = false }
        engine.onPlayPause = { playing.toggle() }

        engine.handleRemoteCommand(.pause)
        engine.handleRemoteCommand(.pause)

        XCTAssertFalse(playing)
    }

    func testToggleStillChangesPlaybackInBothDirections() {
        let engine = makeEngine()
        var playing = false
        engine.onPlayPause = { playing.toggle() }

        engine.handleRemoteCommand(.togglePlayPause)
        XCTAssertTrue(playing)
        engine.handleRemoteCommand(.togglePlayPause)
        XCTAssertFalse(playing)
    }

    private func makeEngine() -> SDRAudioEngine {
        SDRAudioEngine(audioBuffer: AudioRingBuffer(capacity: 16))
    }
}
