import Foundation
import os

/// Lightweight performance tracing using os.signpost.
/// Integrates with Instruments.
public final class PerformanceTrace: @unchecked Sendable {
    private static let pointsOfInterest = OSLog(subsystem: "yo6say.coronasdr", category: .pointsOfInterest)

    public enum TraceName: String {
        case connectLatency = "connect_latency"
        case firstAudioLatency = "first_audio_latency"
        case retuneLatency = "retune_latency"
        case dspBlockProcessing = "dsp_block_processing"
    }

    private let name: TraceName
    private let signpostID: OSSignpostID
    private var startTime: CFAbsoluteTime = 0

    public init(name: TraceName) {
        self.name = name
        self.signpostID = OSSignpostID(log: Self.pointsOfInterest)
    }

    public func start() {
        startTime = CFAbsoluteTimeGetCurrent()
        os_signpost(.begin, log: Self.pointsOfInterest, name: "Trace", signpostID: signpostID, "%{public}s", name.rawValue)
    }

    public func stop() {
        os_signpost(.end, log: Self.pointsOfInterest, name: "Trace", signpostID: signpostID, "%{public}s", name.rawValue)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let ms = elapsed * 1000
        SDRLogger.general.info("\(self.name.rawValue) completed in \(ms)ms")
    }
}
