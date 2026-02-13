import Foundation
import Synchronization

/// Lock-free single-producer single-consumer ring buffer for IQ data.
/// Producer: network thread writes raw bytes.
/// Consumer: DSP thread reads blocks of bytes.
///
/// Uses Swift stdlib Atomic for lock-free head/tail indices.
public final class IQRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer
    private let capacity: Int

    private let head = Atomic<Int>(0)  // write position (producer)
    private let tail = Atomic<Int>(0)  // read position (consumer)

    // Diagnostics
    private let _overrunCount = Atomic<Int>(0)
    private let _underrunCount = Atomic<Int>(0)

    public var overrunCount: Int { _overrunCount.load(ordering: .relaxed) }
    public var underrunCount: Int { _underrunCount.load(ordering: .relaxed) }

    /// Fill level as a fraction 0.0–1.0.
    public var fillLevel: Double {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .acquiring)
        let used = (h - t + capacity) % capacity
        return Double(used) / Double(capacity)
    }

    /// Available bytes for reading.
    public var availableForReading: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .acquiring)
        return (h - t + capacity) % capacity
    }

    /// Available space for writing.
    public var availableForWriting: Int {
        return capacity - 1 - availableForReading
    }

    /// Create ring buffer with given capacity in bytes.
    /// Capacity should accommodate 0.5–2 seconds of IQ data.
    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    /// Write data into the ring buffer (producer side).
    /// Returns the number of bytes actually written. Drops oldest data on overrun.
    @discardableResult
    public func write(_ data: UnsafeRawBufferPointer) -> Int {
        let count = data.count
        guard count > 0 else { return 0 }

        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let available = (capacity - 1 - ((h - t + capacity) % capacity))

        if count > available {
            _overrunCount.wrappingAdd(1, ordering: .relaxed)
            // Advance tail to make room (drop oldest data)
            let drop = count - available
            tail.store((t + drop) % capacity, ordering: .releasing)
        }

        let bytesToWrite = min(count, capacity - 1)
        let writeStart = h

        if writeStart + bytesToWrite <= capacity {
            buffer.baseAddress!.advanced(by: writeStart)
                .copyMemory(from: data.baseAddress!, byteCount: bytesToWrite)
        } else {
            let firstChunk = capacity - writeStart
            buffer.baseAddress!.advanced(by: writeStart)
                .copyMemory(from: data.baseAddress!, byteCount: firstChunk)
            buffer.baseAddress!
                .copyMemory(from: data.baseAddress!.advanced(by: firstChunk), byteCount: bytesToWrite - firstChunk)
        }

        head.store((writeStart + bytesToWrite) % capacity, ordering: .releasing)
        return bytesToWrite
    }

    /// Convenience write from Data.
    @discardableResult
    public func write(_ data: Data) -> Int {
        data.withUnsafeBytes { write($0) }
    }

    /// Read up to `maxCount` bytes from the ring buffer (consumer side).
    /// Returns a Data with the bytes read.
    public func read(maxCount: Int) -> Data {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        let available = (h - t + capacity) % capacity

        if available == 0 {
            _underrunCount.wrappingAdd(1, ordering: .relaxed)
            return Data()
        }

        let count = min(maxCount, available)
        var result = Data(count: count)

        result.withUnsafeMutableBytes { dest in
            let readStart = t
            if readStart + count <= capacity {
                dest.baseAddress!.copyMemory(
                    from: buffer.baseAddress!.advanced(by: readStart),
                    byteCount: count
                )
            } else {
                let firstChunk = capacity - readStart
                dest.baseAddress!.copyMemory(
                    from: buffer.baseAddress!.advanced(by: readStart),
                    byteCount: firstChunk
                )
                dest.baseAddress!.advanced(by: firstChunk).copyMemory(
                    from: buffer.baseAddress!,
                    byteCount: count - firstChunk
                )
            }
        }

        tail.store((t + count) % capacity, ordering: .releasing)
        return result
    }

    /// Read directly into a pre-allocated buffer. Returns actual bytes read.
    public func read(into dest: UnsafeMutableRawBufferPointer, maxCount: Int) -> Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        let available = (h - t + capacity) % capacity

        if available == 0 {
            _underrunCount.wrappingAdd(1, ordering: .relaxed)
            return 0
        }

        let count = min(min(maxCount, available), dest.count)
        let readStart = t

        if readStart + count <= capacity {
            dest.baseAddress!.copyMemory(
                from: buffer.baseAddress!.advanced(by: readStart),
                byteCount: count
            )
        } else {
            let firstChunk = capacity - readStart
            dest.baseAddress!.copyMemory(
                from: buffer.baseAddress!.advanced(by: readStart),
                byteCount: firstChunk
            )
            dest.baseAddress!.advanced(by: firstChunk).copyMemory(
                from: buffer.baseAddress!,
                byteCount: count - firstChunk
            )
        }

        tail.store((t + count) % capacity, ordering: .releasing)
        return count
    }

    /// Flush all data in the buffer.
    public func flush() {
        let h = head.load(ordering: .acquiring)
        tail.store(h, ordering: .releasing)
    }

    /// Reset all state.
    public func reset() {
        head.store(0, ordering: .releasing)
        tail.store(0, ordering: .releasing)
        _overrunCount.store(0, ordering: .relaxed)
        _underrunCount.store(0, ordering: .relaxed)
    }
}
