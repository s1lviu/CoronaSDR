import Foundation

/// Bounded handoff from DSP to one worker. UI polls snapshots; no per-sample MainActor tasks.
public final class DecoderService: @unchecked Sendable {
    private struct Block: Sendable {
        let samples: [Float]
        let stream: UInt64
        let first: UInt64
        let receivedAt: Date
        let revision: UInt64
        let configuration: DecoderConfiguration
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "yo6say.coronasdr.decode", qos: .utility)
    private let ft8: FT8Decoder?
    private var configuration = DecoderConfiguration(mode: .off, frequencyHz: 0)
    private var revision: UInt64 = 0
    private var blocks: [Block] = []
    private var queuedSamples = 0
    private var scheduled = false
    private var state = DecodeSnapshot()
    private var historyRevision: UInt64 = 0
    // Only the serial worker accesses the following state.
    private var workerRevision: UInt64?
    private var stream: UInt64?
    private var expectedIndex: UInt64?
    private var cw: CWDecoder?
    private var window: [Float] = []
    private var windowFirst: Int64 = 0
    private var anchor = Date()
    private var anchorIndex: Int64 = 0
    private var seen: [(payload: String, position: Int64, hz: Float)] = []

    public init() { ft8 = try? FT8Decoder() }

    @discardableResult public func configure(_ configuration: DecoderConfiguration, status: String? = nil) -> UInt64 {
        let token = lock.withLock {
            self.configuration = configuration
            revision &+= 1
            blocks.removeAll(keepingCapacity: true); queuedSamples = 0
            state.progress = 0; state.estimatedWPM = nil
            state.lastWindowSummary = nil; state.lastInterruption = nil
            state.status = status ?? (configuration.mode == .off ? "Decoder off" : "Waiting for receiver samples")
            return revision
        }
        ft8?.cancel()
        return token
    }
    public func snapshot() -> DecodeSnapshot { lock.withLock { state } }
    public func clearHistory() {
        lock.withLock {
            state.transcript = ""; state.messages = []
            historyRevision &+= 1
        }
    }

    public func submit(_ samples: [Float], stream: UInt64, firstSampleIndex: UInt64, receivedAt: Date, configurationRevision: UInt64? = nil) {
        guard !samples.isEmpty else { return }
        let schedule: Bool = lock.withLock {
            guard configuration.mode != .off, configurationRevision == nil || configurationRevision == revision else { return false }
            guard samples.count <= 48000 else {
                blocks.removeAll(keepingCapacity: true); queuedSamples = 0
                state.skippedWindows += 1
                state.status = "Input block too large — reacquiring"
                state.lastInterruption = state.status
                return false
            }
            if queuedSamples + samples.count > 48000 || blocks.count >= 256 {
                blocks.removeAll(keepingCapacity: true); queuedSamples = 0
                state.skippedWindows += 1
                state.status = "Processing limit reached — reacquiring"
                state.lastInterruption = state.status
            }
            blocks.append(Block(samples: samples, stream: stream, first: firstSampleIndex,
                                receivedAt: receivedAt, revision: revision, configuration: configuration))
            queuedSamples += samples.count
            if scheduled { return false }
            scheduled = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            let block: Block? = lock.withLock {
                guard !blocks.isEmpty else { scheduled = false; return nil }
                let block = blocks.removeFirst()
                queuedSamples -= block.samples.count
                return block
            }
            guard let block else { return }
            guard lock.withLock({ block.revision == revision }) else { continue }
            process(block)
        }
    }

    private func process(_ block: Block) {
        let discontinuity = workerRevision != block.revision || stream != block.stream || expectedIndex != block.first
        if discontinuity {
            let previouslyReceiving = expectedIndex != nil
            workerRevision = block.revision; stream = block.stream
            window.removeAll(keepingCapacity: true); seen.removeAll(keepingCapacity: true)
            windowFirst = Int64(clamping: block.first)
            anchor = block.receivedAt; anchorIndex = windowFirst
            cw = CWDecoder(pitchHz: block.configuration.pitchHz, speedWPM: block.configuration.speedWPM,
                           automaticSpeed: block.configuration.automaticSpeed)
            ft8?.reset()
            publish(block) { state in
                state.progress = 0
                if previouslyReceiving {
                    state.status = "Reception changed — reacquiring"
                    state.lastInterruption = "Reception changed; decoding restarted from continuous samples."
                    if block.configuration.mode == .cw && !state.transcript.isEmpty { state.transcript += "\n[Reception changed]\n" }
                }
            }
        }
        expectedIndex = block.first &+ UInt64(block.samples.count)
        // A UTC clock adjustment changes labels, not the sample cadence or decoding windows.
        let expectedDate = anchor.addingTimeInterval(Double(Int64(clamping: block.first) - anchorIndex) / 12000)
        if abs(expectedDate.timeIntervalSince(block.receivedAt)) > 5 {
            anchor = block.receivedAt; anchorIndex = Int64(clamping: block.first)
        }
        switch block.configuration.mode {
        case .off: break
        case .cw:
            let text = cw?.process(block.samples) ?? ""
            let wpm = cw?.estimatedWPM
            let tone = cw?.hasTone == true
            publish(block) { state in
                state.transcript += text
                state.transcript = String(state.transcript.suffix(10000))
                state.estimatedWPM = wpm
                state.status = tone ? "Tracking CW tone" : "No usable CW tone"
            }
        case .ft8:
            guard let ft8 else { publish(block) { $0.status = "FT8 decoder could not allocate memory" }; return }
            window.append(contentsOf: block.samples)
            publish(block) { state in
                state.progress = min(1, Double(window.count) / 216000)
                state.status = "Collecting FT8 audio"
            }
            while window.count >= 216000 {
                guard lock.withLock({ revision == block.revision }) else { return }
                let currentHistory = lock.withLock { historyRevision }
                publish(block) { $0.status = "Decoding FT8 audio" }
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let decoded = try ft8.decode(Array(window.prefix(216000)))
                    var messages: [FT8Message] = []
                    for item in decoded {
                        let position = windowFirst + Int64((Double(item.startSeconds) * 12000).rounded())
                        guard !seen.contains(where: { $0.payload == item.payload && abs($0.position - position) < 4800 && abs($0.hz - item.audioHz) < 6.25 }) else { continue }
                        seen.append((item.payload, position, item.audioHz))
                        messages.append(FT8Message(id: UUID(), text: item.text, payload: item.payload,
                            audioHz: item.audioHz, frequencyHz: block.configuration.frequencyHz,
                            receivedAt: anchor.addingTimeInterval(Double(position - anchorIndex) / 12000),
                            samplePosition: position, supported: item.supported, messageType: item.messageType))
                    }
                    seen.removeAll { $0.position < windowFirst - 216000 }
                    if seen.count > 640 { seen.removeFirst(seen.count - 640) }
                    publish(block) { state in
                        if historyRevision == currentHistory {
                            state.messages += messages.sorted { $0.audioHz < $1.audioHz }
                            if state.messages.count > 200 { state.messages.removeFirst(state.messages.count - 200) }
                        }
                        state.status = decoded.isEmpty ? "No FT8 messages in the last window" : "FT8 window decoded"
                        state.lastWindowSummary = "Last window: \(decoded.count) messages, \(messages.count) new."
                        state.decodeSeconds = ProcessInfo.processInfo.systemUptime - start
                    }
                } catch FT8DecodeError.cancelled {
                    return
                } catch {
                    publish(block) { $0.status = "Invalid FT8 samples — reacquiring"; $0.skippedWindows += 1 }
                    window.removeAll(keepingCapacity: true); expectedIndex = nil
                    return
                }
                // 18-second windows with 3-second hops contain every continuous 12.64-second frame.
                window.removeFirst(36000); windowFirst += 36000
            }
        }
    }
    private func publish(_ block: Block, _ change: (inout DecodeSnapshot) -> Void) {
        lock.withLock { if revision == block.revision { change(&state) } }
    }

    /// Deterministic harness support: waits for currently queued work, never used by the UI or DSP.
    public func waitUntilIdle() { queue.sync {} }
}
