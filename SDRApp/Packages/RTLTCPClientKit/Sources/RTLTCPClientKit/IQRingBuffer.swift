import Foundation

/// Thread-safe ring buffer for IQ data.
/// Producer: network thread writes raw bytes.
/// Consumer: DSP thread reads blocks of bytes.
public final class IQRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer
    private let capacity: Int
    private let lock = NSLock()

    private var head: Int = 0 // write position
    private var tail: Int = 0 // read position

    // Diagnostics
    private var _overrunCount: Int = 0
    private var _underrunCount: Int = 0

    public var overrunCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _overrunCount
    }

    public var underrunCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _underrunCount
    }

    /// Fill level as a fraction 0.0–1.0.
    public var fillLevel: Double {
        lock.lock()
        let used = (head - tail + capacity) % capacity
        lock.unlock()
        return Double(used) / Double(capacity)
    }

    /// Available bytes for reading.
    public var availableForReading: Int {
        lock.lock()
        let available = (head - tail + capacity) % capacity
        lock.unlock()
        return available
    }

    /// Available space for writing.
    public var availableForWriting: Int {
        lock.lock()
        let available = capacity - 1 - ((head - tail + capacity) % capacity)
        lock.unlock()
        return available
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
        guard let sourceBase = data.baseAddress else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        let available = capacity - 1 - ((head - tail + capacity) % capacity)

        if count > available {
            _overrunCount &+= 1
            // Advance tail to make room (drop oldest data)
            let drop = count - available
            tail = (tail + drop) % capacity
        }

        let bytesToWrite = min(count, capacity - 1)
        let writeStart = head

        if writeStart + bytesToWrite <= capacity {
            buffer.baseAddress!.advanced(by: writeStart)
                .copyMemory(from: sourceBase, byteCount: bytesToWrite)
        } else {
            let firstChunk = capacity - writeStart
            buffer.baseAddress!.advanced(by: writeStart)
                .copyMemory(from: sourceBase, byteCount: firstChunk)
            buffer.baseAddress!
                .copyMemory(from: sourceBase.advanced(by: firstChunk), byteCount: bytesToWrite - firstChunk)
        }

        head = (writeStart + bytesToWrite) % capacity
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
        lock.lock()
        defer { lock.unlock() }
        let available = (head - tail + capacity) % capacity

        if available == 0 {
            _underrunCount &+= 1
            return Data()
        }

        let count = min(maxCount, available)
        var result = Data(count: count)

        result.withUnsafeMutableBytes { dest in
            let readStart = tail
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

        tail = (tail + count) % capacity
        return result
    }

    /// Read directly into a pre-allocated buffer. Returns actual bytes read.
    public func read(into dest: UnsafeMutableRawBufferPointer, maxCount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let available = (head - tail + capacity) % capacity

        if available == 0 {
            _underrunCount &+= 1
            return 0
        }

        let count = min(min(maxCount, available), dest.count)
        let readStart = tail

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

        tail = (tail + count) % capacity
        return count
    }

    /// Flush all data in the buffer.
    public func flush() {
        lock.lock()
        tail = head
        lock.unlock()
    }

    /// Reset all state.
    public func reset() {
        lock.lock()
        head = 0
        tail = 0
        _overrunCount = 0
        _underrunCount = 0
        lock.unlock()
    }
}
