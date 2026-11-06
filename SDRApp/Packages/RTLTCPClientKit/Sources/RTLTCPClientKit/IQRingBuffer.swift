import Foundation

public struct IQRead: Sendable {
    public let byteCount: Int
    public let firstSampleIndex: UInt64
    public let generation: UInt64
    public let droppedSamples: UInt64
}

/// Reads and evictions preserve I/Q pairs across arbitrary TCP chunk boundaries.
public final class IQRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer
    private let capacity: Int
    private let lock = NSLock()
    private var head = 0
    private var tail = 0
    private var used = 0
    private var streamBytes: UInt64 = 0
    private var firstIndex: UInt64 = 0
    private var pendingI: UInt8?
    private var generation: UInt64 = 0
    private var dropped: UInt64 = 0
    private var overruns = 0
    private var underruns = 0

    public init(capacity: Int) {
        precondition(capacity >= 4)
        self.capacity = capacity & ~1
        buffer = .allocate(byteCount: self.capacity, alignment: 16)
    }
    deinit { buffer.deallocate() }
    public var overrunCount: Int { lock.withLock { overruns } }
    public var underrunCount: Int { lock.withLock { underruns } }
    public var fillLevel: Double { lock.withLock { Double(used) / Double(capacity) } }
    public var availableForReading: Int { lock.withLock { used } }
    public var availableForWriting: Int { lock.withLock { capacity - used } }

    /// Returns consumed bytes, including any trailing I retained until its Q arrives.
    @discardableResult public func write(_ data: UnsafeRawBufferPointer) -> Int {
        guard let base = data.baseAddress, !data.isEmpty else { return 0 }
        return lock.withLock {
            var offset = 0
            if streamBytes & 1 != 0 {
                if let i = pendingI {
                    var pair = (i, data[0])
                    withUnsafeBytes(of: &pair) { append($0.baseAddress!, count: 2) }
                } else { dropped &+= 1 }
                streamBytes &+= 1
                pendingI = nil
                offset = 1
            }
            let complete = (data.count - offset) & ~1
            if complete > 0 {
                let keep = min(complete, capacity)
                let skip = complete - keep
                if skip > 0 {
                    dropped &+= UInt64((used + skip) / 2)
                    generation &+= 1; overruns &+= 1
                    used = 0; tail = head
                }
                streamBytes &+= UInt64(skip)
                append(base.advanced(by: offset + skip), count: keep)
                streamBytes &+= UInt64(keep)
                offset += complete
            }
            if offset < data.count {
                pendingI = data[offset]
                streamBytes &+= 1
            }
            return data.count
        }
    }
    private func append(_ source: UnsafeRawPointer, count: Int) {
        let evict = max(0, used + count - capacity)
        if evict > 0 {
            tail = (tail + evict) % capacity
            used -= evict
            firstIndex &+= UInt64(evict / 2)
            dropped &+= UInt64(evict / 2)
            generation &+= 1; overruns &+= 1
        }
        if used == 0 { firstIndex = streamBytes / 2 }
        let first = min(count, capacity - head)
        buffer.baseAddress!.advanced(by: head).copyMemory(from: source, byteCount: first)
        if first < count { buffer.baseAddress!.copyMemory(from: source.advanced(by: first), byteCount: count - first) }
        head = (head + count) % capacity
        used += count
    }
    @discardableResult public func write(_ data: Data) -> Int { data.withUnsafeBytes { write($0) } }

    /// Metadata and samples are read under the same lock.
    public func readBlock(into dest: UnsafeMutableRawBufferPointer, maxCount: Int) -> IQRead {
        lock.withLock {
            let count = max(0, min(used, min(dest.count, maxCount))) & ~1
            let metadata = IQRead(byteCount: count, firstSampleIndex: firstIndex, generation: generation, droppedSamples: dropped)
            guard count > 0, let out = dest.baseAddress else { underruns &+= 1; return metadata }
            let first = min(count, capacity - tail)
            out.copyMemory(from: buffer.baseAddress!.advanced(by: tail), byteCount: first)
            if first < count { out.advanced(by: first).copyMemory(from: buffer.baseAddress!, byteCount: count - first) }
            tail = (tail + count) % capacity
            used -= count
            firstIndex &+= UInt64(count / 2)
            return metadata
        }
    }
    public func read(into dest: UnsafeMutableRawBufferPointer, maxCount: Int) -> Int {
        readBlock(into: dest, maxCount: maxCount).byteCount
    }
    public func read(maxCount: Int) -> Data {
        var data = Data(count: max(0, min(maxCount, capacity)))
        let count = data.withUnsafeMutableBytes { read(into: $0, maxCount: maxCount) }
        data.count = count
        return data
    }
    /// Discard incoming bytes while preserving stream parity across settling windows.
    public func discard(byteCount: Int) {
        guard byteCount > 0 else { return }
        lock.withLock {
            dropped &+= UInt64(used / 2) + (streamBytes + UInt64(byteCount)) / 2 - streamBytes / 2
            streamBytes &+= UInt64(byteCount)
            used = 0; tail = head; pendingI = nil
            generation &+= 1
        }
    }
    public func flush() {
        lock.withLock {
            dropped &+= UInt64(used / 2)
            used = 0; tail = head; pendingI = nil
            generation &+= 1
        }
    }
    /// A new stream starts with I. A flush of the same stream must preserve parity instead.
    public func reset() {
        lock.withLock {
            head = 0; tail = 0; used = 0; streamBytes = 0; firstIndex = 0; pendingI = nil
            overruns = 0; underruns = 0; dropped = 0
            generation &+= 1
        }
    }
}
