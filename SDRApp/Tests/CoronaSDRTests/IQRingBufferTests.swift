import XCTest
import Foundation
import RTLTCPClientKit

final class IQRingBufferTests: XCTestCase {
    func testWriteReadWrapAroundPreservesOrder() {
        let buffer = IQRingBuffer(capacity: 16)

        let first = Data((0..<10).map(UInt8.init))
        let second = Data((10..<16).map(UInt8.init))

        XCTAssertEqual(buffer.write(first), 10)
        XCTAssertEqual(Array(buffer.read(maxCount: 6)), Array((0..<6).map(UInt8.init)))

        XCTAssertEqual(buffer.write(second), 6)
        XCTAssertEqual(Array(buffer.read(maxCount: 16)), Array((6..<16).map(UInt8.init)))
        XCTAssertEqual(buffer.overrunCount, 0)
    }

    func testOverrunDropsOldestBytes() {
        let buffer = IQRingBuffer(capacity: 8) // max storable = 7 bytes

        XCTAssertEqual(buffer.write(Data((0..<7).map(UInt8.init))), 7)
        XCTAssertEqual(buffer.write(Data((7..<11).map(UInt8.init))), 4)

        XCTAssertEqual(Array(buffer.read(maxCount: 7)), Array((4..<11).map(UInt8.init)))
        XCTAssertEqual(buffer.overrunCount, 1)
    }

    func testReadIntoBufferHandlesWrapAround() {
        let buffer = IQRingBuffer(capacity: 12)

        XCTAssertEqual(buffer.write(Data((1...8).map(UInt8.init))), 8)
        _ = buffer.read(maxCount: 5)
        XCTAssertEqual(buffer.write(Data((9...13).map(UInt8.init))), 5)

        let dest = UnsafeMutableRawBufferPointer.allocate(byteCount: 8, alignment: 16)
        defer { dest.deallocate() }

        let read = buffer.read(into: dest, maxCount: 8)
        let values = Array(dest.bindMemory(to: UInt8.self).prefix(read))
        XCTAssertEqual(read, 8)
        XCTAssertEqual(values, Array((6...13).map(UInt8.init)))
    }

    func testUnderrunCountIncrementsWhenReadingEmptyBuffer() {
        let buffer = IQRingBuffer(capacity: 16)
        XCTAssertEqual(buffer.underrunCount, 0)

        XCTAssertTrue(buffer.read(maxCount: 32).isEmpty)
        XCTAssertEqual(buffer.underrunCount, 1)

        let dest = UnsafeMutableRawBufferPointer.allocate(byteCount: 16, alignment: 16)
        defer { dest.deallocate() }
        XCTAssertEqual(buffer.read(into: dest, maxCount: 16), 0)
        XCTAssertEqual(buffer.underrunCount, 2)
    }

    func testPerformanceWriteReadRawPath() {
        let buffer = IQRingBuffer(capacity: 1 << 20)
        let chunkSize = 16_384
        let iterations = 300
        let source = Data((0..<chunkSize).map { UInt8($0 & 0xFF) })
        let dest = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { dest.deallocate() }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            buffer.reset()
            for _ in 0..<iterations {
                source.withUnsafeBytes { bytes in
                    _ = buffer.write(bytes)
                }
                _ = buffer.read(into: dest, maxCount: chunkSize)
            }
        }
    }
}
