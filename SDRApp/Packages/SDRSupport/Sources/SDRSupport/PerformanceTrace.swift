import Foundation
import os

/// Lightweight performance tracing using os.signpost.
/// Integrates with Instruments.
public final class PerformanceTrace: @unchecked Sendable {
    private static let pointsOfInterest = OSLog(subsystem: "yo6say.coronasdr", category: .pointsOfInterest)
    public typealias Reporter = @Sendable (_ name: TraceName, _ durationMs: Double, _ metadata: [String: String]) -> Void
    private static let reporterLock = NSLock()
    private nonisolated(unsafe) static var reporter: Reporter?

    public enum TraceName: String {
        case connectLatency = "connect_latency"
        case firstAudioLatency = "first_audio_latency"
        case retuneLatency = "retune_latency"
        case dspBlockProcessing = "dsp_block_processing"
    }

    private let name: TraceName
    private let metadata: [String: String]
    private let signpostID: OSSignpostID
    private var startTime: CFAbsoluteTime = 0
    private var isActive: Bool = false

    public init(name: TraceName, metadata: [String: String] = [:]) {
        self.name = name
        self.metadata = metadata
        self.signpostID = OSSignpostID(log: Self.pointsOfInterest)
    }

    public static func setReporter(_ reporter: Reporter?) {
        reporterLock.lock()
        Self.reporter = reporter
        reporterLock.unlock()
    }

    public static func reportDuration(name: TraceName, durationMs: Double, metadata: [String: String] = [:]) {
        SDRLogger.general.info("\(name.rawValue) completed in \(durationMs)ms")
        notifyReporter(name: name, durationMs: durationMs, metadata: metadata)
    }

    public func start() {
        guard !isActive else { return }
        isActive = true
        startTime = CFAbsoluteTimeGetCurrent()
        os_signpost(.begin, log: Self.pointsOfInterest, name: "Trace", signpostID: signpostID, "%{public}s", name.rawValue)
    }

    public func stop() {
        guard isActive else { return }
        isActive = false
        os_signpost(.end, log: Self.pointsOfInterest, name: "Trace", signpostID: signpostID, "%{public}s", name.rawValue)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let ms = elapsed * 1000
        SDRLogger.general.info("\(self.name.rawValue) completed in \(ms)ms")
        Self.notifyReporter(name: name, durationMs: ms, metadata: metadata)
    }

    /// End the trace without emitting telemetry.
    public func cancel() {
        guard isActive else { return }
        isActive = false
        os_signpost(.end, log: Self.pointsOfInterest, name: "Trace", signpostID: signpostID, "%{public}s", name.rawValue)
    }

    private static func notifyReporter(name: TraceName, durationMs: Double, metadata: [String: String]) {
        reporterLock.lock()
        let reporter = Self.reporter
        reporterLock.unlock()
        reporter?(name, durationMs, metadata)
    }
}
