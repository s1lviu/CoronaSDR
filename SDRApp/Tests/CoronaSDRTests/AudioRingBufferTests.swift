import XCTest
import AudioEngineKit

final class AudioRingBufferTests: XCTestCase {
    func testAudioEngineStartsWithStereoRingBuffer() throws {
        let buffer = AudioRingBuffer(capacity: 48_001)
        let engine = SDRAudioEngine(audioBuffer: buffer)

        try engine.configureSession()
        try engine.start()
        engine.stop()
    }

    func testWriteReadWrapAroundPreservesOrder() {
        let buffer = AudioRingBuffer(capacity: 16)
        let first = (0..<10).map { Float($0) }
        let second = (10..<16).map { Float($0) }

        XCTAssertEqual(buffer.write(first), 10)
        let firstRead = read(from: buffer, count: 6)
        XCTAssertEqual(firstRead.actual, 6)
        XCTAssertEqual(firstRead.samples, (0..<6).map { Float($0) })

        XCTAssertEqual(buffer.write(second), 6)
        let secondRead = read(from: buffer, count: 10)
        XCTAssertEqual(secondRead.actual, 10)
        XCTAssertEqual(secondRead.samples, (6..<16).map { Float($0) })
        XCTAssertEqual(buffer.overrunCount, 0)
    }

    func testOverrunDropsOldestSamples() {
        let buffer = AudioRingBuffer(capacity: 8) // max storable = 7 samples

        XCTAssertEqual(buffer.write((0..<7).map { Float($0) }), 7)
        XCTAssertEqual(buffer.write((7..<11).map { Float($0) }), 4)

        let readResult = read(from: buffer, count: 7)
        XCTAssertEqual(readResult.actual, 7)
        XCTAssertEqual(readResult.samples, (4..<11).map { Float($0) })
        XCTAssertEqual(buffer.overrunCount, 1)
    }

    func testUnderrunFillsRemainderWithSilence() {
        let buffer = AudioRingBuffer(capacity: 16)
        XCTAssertEqual(buffer.write([0.25, -0.25]), 2)

        var destination = [Float](repeating: -1.0, count: 5)
        let actual = destination.withUnsafeMutableBufferPointer { ptr in
            buffer.read(into: ptr, count: 5)
        }

        XCTAssertEqual(actual, 2)
        XCTAssertEqual(destination[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(destination[1], -0.25, accuracy: 0.0001)
        XCTAssertEqual(destination[2], 0.0, accuracy: 0.0001)
        XCTAssertEqual(destination[3], 0.0, accuracy: 0.0001)
        XCTAssertEqual(destination[4], 0.0, accuracy: 0.0001)
        XCTAssertEqual(buffer.underrunCount, 1)
    }

    func testInterleavedStereoSamplesPreserveChannelOrder() {
        let buffer = AudioRingBuffer(capacity: 16)
        let stereoFrames: [Float] = [
            1.0, -1.0,
            0.75, -0.75,
            0.5, -0.5
        ]

        XCTAssertEqual(buffer.write(stereoFrames), stereoFrames.count)
        let readResult = read(from: buffer, count: stereoFrames.count)

        XCTAssertEqual(readResult.actual, stereoFrames.count)
        XCTAssertEqual(readResult.samples, stereoFrames)
    }

    func testPerformanceWriteReadHotPath() {
        let buffer = AudioRingBuffer(capacity: 65_536)
        let chunkSize = 4_096
        let iterations = 500
        let source = (0..<chunkSize).map { Float($0 % 1024) / 1024.0 }
        var destination = [Float](repeating: 0, count: chunkSize)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            buffer.reset()
            source.withUnsafeBufferPointer { src in
                destination.withUnsafeMutableBufferPointer { dst in
                    for _ in 0..<iterations {
                        _ = buffer.write(src)
                        _ = buffer.read(into: dst, count: chunkSize)
                    }
                }
            }
        }
    }

    private func read(from buffer: AudioRingBuffer, count: Int) -> (actual: Int, samples: [Float]) {
        var destination = [Float](repeating: 0, count: count)
        let actual = destination.withUnsafeMutableBufferPointer { ptr in
            buffer.read(into: ptr, count: count)
        }
        return (actual, Array(destination.prefix(actual)))
    }
}
