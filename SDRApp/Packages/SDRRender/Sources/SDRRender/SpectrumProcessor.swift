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
    private var floorProbeBins: [Float] = []

    // Display window (dBFS): renderer maps [minDB ... maxDB] to [0 ... 1].
    // Industry-standard behavior: keep a fixed dynamic range and move level based on noise floor.
    public var minDB: Float = -110
    public var maxDB: Float = -50
    public var dynamicRangeDB: Float = 60
    public var autoLevelEnabled: Bool = true
    public var levelHeadroomDB: Float = 4

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
        updateDisplayWindow(using: smoothed)

        // Peak hold
        if peakHoldEnabled {
            if peakBins.count != count {
                peakBins = smoothed
            }
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
        let range = max(1, maxDB - minDB)
        return currentBins.map { bin in
            max(0, min(1, (bin - minDB) / range))
        }
    }

    private func updateDisplayWindow(using bins: [Float]) {
        let clampedRange = max(20, min(120, dynamicRangeDB))

        if !autoLevelEnabled {
            maxDB = minDB + clampedRange
            return
        }

        guard let estimatedFloor = estimateNoiseFloor(from: bins) else {
            maxDB = minDB + clampedRange
            return
        }

        let targetMinDB = estimatedFloor - levelHeadroomDB
        let delta = targetMinDB - minDB

        // Fast attack when floor rises, slower release when it falls.
        let alpha: Float = delta > 0 ? 0.35 : 0.08
        minDB += delta * alpha
        maxDB = minDB + clampedRange
    }

    private func estimateNoiseFloor(from bins: [Float]) -> Float? {
        guard !bins.isEmpty else { return nil }

        // Downsample before sorting to reduce per-frame CPU while staying robust.
        let stride = max(1, bins.count / 512)
        floorProbeBins.removeAll(keepingCapacity: true)
        floorProbeBins.reserveCapacity((bins.count / stride) + 1)

        var index = 0
        while index < bins.count {
            floorProbeBins.append(bins[index])
            index += stride
        }

        guard !floorProbeBins.isEmpty else { return nil }
        floorProbeBins.sort()

        // 20th percentile is a stable proxy for floor without being dominated by peaks.
        let percentile: Float = 0.20
        let percentileIndex = Int((Float(floorProbeBins.count - 1) * percentile).rounded(.down))
        return floorProbeBins[max(0, min(percentileIndex, floorProbeBins.count - 1))]
    }
}
