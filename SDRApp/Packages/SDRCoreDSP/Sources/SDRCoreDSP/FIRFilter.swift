import Foundation
import Accelerate

/// FIR low-pass filter with decimation support.
/// Uses Accelerate vDSP_desamp for vectorized filtering + decimation.
/// Implements overlap-save method for seamless block processing.
public final class FIRFilter {
    private var taps: [Float]
    private var history: [Float] // numTaps-1 samples of overlap
    private let numTaps: Int
    public let decimationFactor: Int
    private var extendedBuffer: [Float] = []

    /// Create a FIR low-pass filter.
    /// - Parameters:
    ///   - cutoffNormalized: Normalized cutoff frequency (0.0–1.0, where 1.0 = Nyquist).
    ///   - numTaps: Number of filter taps (odd recommended, e.g. 63, 127).
    ///   - decimationFactor: Decimation factor (keep every Nth sample).
    public init(cutoffNormalized: Float, numTaps: Int = 63, decimationFactor: Int = 1) {
        self.numTaps = numTaps
        self.decimationFactor = decimationFactor
        self.taps = FIRFilter.designLowPass(cutoff: cutoffNormalized, numTaps: numTaps)
        self.history = [Float](repeating: 0, count: numTaps - 1)
        self.extendedBuffer = [Float](repeating: 0, count: numTaps - 1)
    }

    /// Create from pre-computed taps.
    public init(taps: [Float], decimationFactor: Int = 1) {
        self.numTaps = taps.count
        self.taps = taps
        self.decimationFactor = decimationFactor
        self.history = [Float](repeating: 0, count: numTaps - 1)
        self.extendedBuffer = [Float](repeating: 0, count: numTaps - 1)
    }

    /// Filter and decimate a block of real samples.
    /// Returns the decimated output using overlap-save.
    public func process(_ input: [Float]) -> [Float] {
        var output: [Float] = []
        _ = process(input, into: &output)
        return output
    }

    /// Allocation-aware path: writes filtered/decimated samples into caller-provided storage.
    /// Returns the number of valid output samples written.
    @discardableResult
    public func process(_ input: [Float], into output: inout [Float]) -> Int {
        guard !input.isEmpty else {
            output.removeAll(keepingCapacity: true)
            return 0
        }

        // Overlap-save: prepend (numTaps-1) history samples.
        let overlap = numTaps - 1
        let extendedCount = overlap + input.count
        ensureExtendedCapacity(extendedCount)

        if overlap > 0 {
            history.withUnsafeBufferPointer { hist in
                extendedBuffer.withUnsafeMutableBufferPointer { ext in
                    ext.baseAddress!.update(from: hist.baseAddress!, count: overlap)
                }
            }
        }
        input.withUnsafeBufferPointer { src in
            extendedBuffer.withUnsafeMutableBufferPointer { ext in
                ext.baseAddress!.advanced(by: overlap).update(from: src.baseAddress!, count: input.count)
            }
        }

        // Output count: decimated samples from NEW input only.
        let outputCount = input.count / decimationFactor
        guard outputCount > 0 else {
            saveHistory(fromExtendedCount: extendedCount)
            output.removeAll(keepingCapacity: true)
            return 0
        }

        let validOutputs = min(
            outputCount,
            max(0, (extendedCount - numTaps) / decimationFactor + 1)
        )
        if validOutputs <= 0 {
            saveHistory(fromExtendedCount: extendedCount)
            output.removeAll(keepingCapacity: true)
            return 0
        }

        if output.count != validOutputs {
            output = [Float](repeating: 0, count: validOutputs)
        }

        // vDSP_desamp: C[n] = sum_{p=0}^{P-1} A[n*DF + p] * F[p]
        extendedBuffer.withUnsafeBufferPointer { ext in
            taps.withUnsafeBufferPointer { t in
                output.withUnsafeMutableBufferPointer { out in
                    vDSP_desamp(
                        ext.baseAddress!,
                        vDSP_Stride(decimationFactor),
                        t.baseAddress!,
                        out.baseAddress!,
                        vDSP_Length(validOutputs),
                        vDSP_Length(numTaps)
                    )
                }
            }
        }

        // Save last (numTaps-1) samples for next block.
        saveHistory(fromExtendedCount: extendedCount)
        return validOutputs
    }

    private func ensureExtendedCapacity(_ requiredCount: Int) {
        if extendedBuffer.count < requiredCount {
            extendedBuffer = [Float](repeating: 0, count: requiredCount)
        }
    }

    private func saveHistory(fromExtendedCount extendedCount: Int) {
        let overlap = numTaps - 1
        guard overlap > 0 else { return }
        let start = max(0, extendedCount - overlap)
        if start + overlap <= extendedBuffer.count {
            for i in 0..<overlap {
                history[i] = extendedBuffer[start + i]
            }
        } else {
            history = [Float](repeating: 0, count: overlap)
        }
    }

    public func reset() {
        history = [Float](repeating: 0, count: numTaps - 1)
    }

    // MARK: - Filter Design

    /// Design a windowed-sinc low-pass FIR filter.
    /// - Parameters:
    ///   - cutoff: Normalized cutoff (0.0–1.0 where 1.0 = Nyquist = sampleRate/2).
    ///   - numTaps: Number of taps (odd recommended).
    /// - Returns: Filter coefficients.
    public static func designLowPass(cutoff: Float, numTaps: Int) -> [Float] {
        let m = numTaps - 1
        let half = Float(m) / 2.0
        var taps = [Float](repeating: 0, count: numTaps)

        let omega = Float.pi * cutoff

        for i in 0..<numTaps {
            let n = Float(i) - half
            if abs(n) < 1e-6 {
                taps[i] = cutoff
            } else {
                taps[i] = sin(omega * n) / (Float.pi * n)
            }

            // Hamming window
            let window = 0.54 - 0.46 * cos(2.0 * Float.pi * Float(i) / Float(m))
            taps[i] *= window
        }

        // Normalize
        var sum: Float = 0
        vDSP_sve(taps, 1, &sum, vDSP_Length(numTaps))
        if sum > 0 {
            var invSum = 1.0 / sum
            vDSP_vsmul(taps, 1, &invSum, &taps, 1, vDSP_Length(numTaps))
        }

        return taps
    }
}
