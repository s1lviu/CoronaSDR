import Foundation

/// Thread-safe ring buffer for Float32 audio samples.
/// Producer: DSP thread writes demodulated audio.
/// Consumer: AVAudioEngine source node callback reads audio.
///
/// CRITICAL: No allocations in the consumer path (audio callback).
public final class AudioRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<Float>
    private let capacity: Int // in samples
    private let lock = NSLock()

    private var head: Int = 0 // write position
    private var tail: Int = 0 // read position

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

    /// Available samples for reading.
    public var availableForReading: Int {
        lock.lock()
        let available = (head - tail + capacity) % capacity
        lock.unlock()
        return available
    }

    /// Total ring buffer capacity in samples.
    public var capacitySamples: Int { capacity }

    /// Create audio ring buffer. Capacity in samples (e.g. 48000 for 1 second at 48kHz).
    public init(capacity: Int) {
        self.capacity = capacity
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        ptr.initialize(repeating: 0, count: capacity)
        self.buffer = UnsafeMutableBufferPointer(start: ptr, count: capacity)
    }

    deinit {
        buffer.baseAddress?.deinitialize(count: capacity)
        buffer.baseAddress?.deallocate()
    }

    /// Write samples into the buffer (producer/DSP side).
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let count = samples.count
        guard count > 0 else { return 0 }
        guard let sourceBase = samples.baseAddress else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        let available = capacity - 1 - ((head - tail + capacity) % capacity)

        if count > available {
            _overrunCount &+= 1
            // Advance tail to make room
            let drop = count - available
            tail = (tail + drop) % capacity
        }

        let samplesToWrite = min(count, capacity - 1)
        let writeStart = head

        if writeStart + samplesToWrite <= capacity {
            buffer.baseAddress!.advanced(by: writeStart)
                .update(from: sourceBase, count: samplesToWrite)
        } else {
            let firstChunk = capacity - writeStart
            buffer.baseAddress!.advanced(by: writeStart)
                .update(from: sourceBase, count: firstChunk)
            buffer.baseAddress!
                .update(from: sourceBase.advanced(by: firstChunk), count: samplesToWrite - firstChunk)
        }

        head = (writeStart + samplesToWrite) % capacity
        return samplesToWrite
    }

    /// Convenience write from Array.
    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// Read samples into a pre-allocated buffer (consumer/audio callback side).
    /// MUST NOT ALLOCATE. Returns actual samples read.
    /// Fills remainder with silence (zero) if not enough data.
    public func read(into dest: UnsafeMutableBufferPointer<Float>, count requestedCount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let available = (head - tail + capacity) % capacity

        let count = min(requestedCount, available)

        if count > 0 {
            let readStart = tail
            if readStart + count <= capacity {
                dest.baseAddress!.update(
                    from: buffer.baseAddress!.advanced(by: readStart),
                    count: count
                )
            } else {
                let firstChunk = capacity - readStart
                dest.baseAddress!.update(
                    from: buffer.baseAddress!.advanced(by: readStart),
                    count: firstChunk
                )
                dest.baseAddress!.advanced(by: firstChunk).update(
                    from: buffer.baseAddress!,
                    count: count - firstChunk
                )
            }
            tail = (tail + count) % capacity
        }

        // Fill remainder with silence
        if count < requestedCount {
            _underrunCount &+= 1
            dest.baseAddress!.advanced(by: count)
                .initialize(repeating: 0, count: requestedCount - count)
        }

        return count
    }

    /// Flush all data.
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
