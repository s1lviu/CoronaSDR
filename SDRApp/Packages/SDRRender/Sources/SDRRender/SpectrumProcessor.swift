import Foundation
import Accelerate
import Observation

/// Processes FFT frames into spectrum bins with smoothing and peak hold.
@Observable
public final class SpectrumProcessor {
    public var currentBins: [Float] = []
    public var peakBins: [Float] = []
    public private(set) var normalizedCurrentBins: [Float] = []
    public private(set) var normalizedPeakBins: [Float] = []
    public var peakHoldEnabled: Bool = false {
        didSet {
            if !peakHoldEnabled {
                peakBins = []
                normalizedPeakBins = []
            }
        }
    }

    private var smoothedBins: [Float] = []
    private var smoothingWork: [Float] = []
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
        guard count > 0 else {
            currentBins = []
            smoothedBins = []
            normalizedCurrentBins = []
            if !peakHoldEnabled {
                peakBins = []
                normalizedPeakBins = []
            }
            return
        }

        if smoothedBins.count != count {
            smoothedBins = bins
            smoothingWork = [Float](repeating: 0, count: count)
            peakBins = bins
            currentBins = bins
            updateDisplayWindow(using: bins)
            refreshNormalizedCurrent()
            if peakHoldEnabled {
                refreshNormalizedPeaks()
            } else {
                normalizedPeakBins = []
            }
            return
        }

        // EMA smoothing
        var alpha = smoothingAlpha
        var oneMinusAlpha = 1.0 - alpha
        if smoothingWork.count != count {
            smoothingWork = [Float](repeating: 0, count: count)
        }

        // smoothed = alpha * new + (1 - alpha) * old
        vDSP_vsmsma(
            bins, 1, &alpha,
            smoothedBins, 1, &oneMinusAlpha,
            &smoothingWork, 1,
            vDSP_Length(count)
        )

        swap(&smoothedBins, &smoothingWork)
        currentBins = smoothedBins

        updateDisplayWindow(using: smoothedBins)
        refreshNormalizedCurrent()

        // Peak hold
        if peakHoldEnabled {
            if peakBins.count != count {
                peakBins = smoothedBins
            }
            for i in 0..<count {
                if smoothedBins[i] > peakBins[i] {
                    peakBins[i] = smoothedBins[i]
                } else {
                    peakBins[i] -= peakDecayRate
                }
            }
            refreshNormalizedPeaks()
        } else {
            normalizedPeakBins = []
        }
    }

    /// Normalize bins to 0.0–1.0 range for rendering.
    public func normalizedBins() -> [Float] {
        normalizedCurrentBins
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

    private func refreshNormalizedCurrent() {
        normalize(currentBins, into: &normalizedCurrentBins)
    }

    private func refreshNormalizedPeaks() {
        normalize(peakBins, into: &normalizedPeakBins)
    }

    private func normalize(_ source: [Float], into destination: inout [Float]) {
        guard !source.isEmpty else {
            destination = []
            return
        }
        if destination.count != source.count {
            destination = [Float](repeating: 0, count: source.count)
        }

        let range = max(1, maxDB - minDB)
        let invRange = 1.0 / range
        for i in 0..<source.count {
            let normalized = (source[i] - minDB) * invRange
            if normalized <= 0 {
                destination[i] = 0
            } else if normalized >= 1 {
                destination[i] = 1
            } else {
                destination[i] = normalized
            }
        }
    }
}
