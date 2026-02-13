import Foundation
import os

/// Collects and exposes real-time diagnostic metrics for the diagnostics screen.
@Observable
public final class DiagnosticsCollector {
    // Network
    public var throughputBytesPerSec: Double = 0
    public var iqBufferFillPercent: Double = 0

    // Audio
    public var audioBufferFillPercent: Double = 0
    public var audioUnderrunCount: Int = 0
    public var audioOverrunCount: Int = 0

    // Rendering
    public var droppedFrameCount: Int = 0
    public var currentFPS: Double = 0

    // DSP
    public var currentSampleRate: Int = 0
    public var currentFFTSize: Int = 0
    public var dspBlockTimeMs: Double = 0

    // Connection
    public var isConnected: Bool = false
    public var reconnectCount: Int = 0
    public var lastError: String?

    public init() {}

    public func reset() {
        throughputBytesPerSec = 0
        iqBufferFillPercent = 0
        audioBufferFillPercent = 0
        audioUnderrunCount = 0
        audioOverrunCount = 0
        droppedFrameCount = 0
        currentFPS = 0
        dspBlockTimeMs = 0
        isConnected = false
        reconnectCount = 0
        lastError = nil
    }
}
