import Foundation
import Accelerate
import Observation

/// Processes FFT frames into spectrum bins with smoothing and peak hold.
@Observable
public final class SpectrumProcessor {
    public var currentBins: [Float] = []
    public var peakBins: [Float] = []
    public var peakHoldEnabled: Bool = false

    private var smoothedBins: [Float] = []
    private let smoothingAlpha: Float = 0.3 // EMA factor
    private let peakDecayRate: Float = 0.2  // dB per update

    public var minDB: Float = -100
    public var maxDB: Float = -20

    public init() {}

    /// Update with a new FFT frame.
    public func update(bins: [Float]) {
        let count = bins.count

        if smoothedBins.count != count {
            smoothedBins = bins
            peakBins = bins
            currentBins = bins
            return
        }

        // EMA smoothing
        var alpha = smoothingAlpha
        var oneMinusAlpha = 1.0 - alpha
        var smoothed = [Float](repeating: 0, count: count)

        // smoothed = alpha * new + (1 - alpha) * old
        vDSP_vsmsma(
            bins, 1, &alpha,
            smoothedBins, 1, &oneMinusAlpha,
            &smoothed, 1,
            vDSP_Length(count)
        )

        smoothedBins = smoothed
        currentBins = smoothed

        // Peak hold
        if peakHoldEnabled {
            for i in 0..<count {
                if smoothed[i] > peakBins[i] {
                    peakBins[i] = smoothed[i]
                } else {
                    peakBins[i] -= peakDecayRate
                }
            }
        }
    }

    /// Normalize bins to 0.0–1.0 range for rendering.
    public func normalizedBins() -> [Float] {
        let range = maxDB - minDB
        guard range > 0 else { return currentBins.map { _ in Float(0.5) } }

        return currentBins.map { bin in
            max(0, min(1, (bin - minDB) / range))
        }
    }
}
