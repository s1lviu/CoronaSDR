import Foundation
import Synchronization

/// Lock-free single-producer single-consumer ring buffer for Float32 audio samples.
/// Producer: DSP thread writes demodulated audio.
/// Consumer: AVAudioEngine source node callback reads audio.
///
/// CRITICAL: No allocations in the consumer path (audio callback).
public final class AudioRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<Float>
    private let capacity: Int // in samples

    private let head = Atomic<Int>(0)  // write position
    private let tail = Atomic<Int>(0)  // read position

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

    /// Available samples for reading.
    public var availableForReading: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .acquiring)
        return (h - t + capacity) % capacity
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

        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let available = capacity - 1 - ((h - t + capacity) % capacity)

        if count > available {
            _overrunCount.wrappingAdd(1, ordering: .relaxed)
            // Advance tail to make room
            let drop = count - available
            tail.store((t + drop) % capacity, ordering: .releasing)
        }

        let samplesToWrite = min(count, capacity - 1)

        if h + samplesToWrite <= capacity {
            buffer.baseAddress!.advanced(by: h)
                .update(from: samples.baseAddress!, count: samplesToWrite)
        } else {
            let firstChunk = capacity - h
            buffer.baseAddress!.advanced(by: h)
                .update(from: samples.baseAddress!, count: firstChunk)
            buffer.baseAddress!
                .update(from: samples.baseAddress!.advanced(by: firstChunk), count: samplesToWrite - firstChunk)
        }

        head.store((h + samplesToWrite) % capacity, ordering: .releasing)
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
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        let available = (h - t + capacity) % capacity

        let count = min(requestedCount, available)

        if count > 0 {
            let readStart = t
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
            tail.store((t + count) % capacity, ordering: .releasing)
        }

        // Fill remainder with silence
        if count < requestedCount {
            _underrunCount.wrappingAdd(1, ordering: .relaxed)
            dest.baseAddress!.advanced(by: count)
                .initialize(repeating: 0, count: requestedCount - count)
        }

        return count
    }

    /// Flush all data.
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
