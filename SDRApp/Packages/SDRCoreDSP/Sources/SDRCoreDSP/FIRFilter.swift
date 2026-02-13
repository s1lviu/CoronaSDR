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
    }

    /// Create from pre-computed taps.
    public init(taps: [Float], decimationFactor: Int = 1) {
        self.numTaps = taps.count
        self.taps = taps
        self.decimationFactor = decimationFactor
        self.history = [Float](repeating: 0, count: numTaps - 1)
    }

    /// Filter and decimate a block of real samples.
    /// Returns the decimated output using overlap-save.
    public func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }

        // Overlap-save: prepend (numTaps-1) history samples
        let overlap = numTaps - 1
        let extended = [Float](unsafeUninitializedCapacity: overlap + input.count) { buffer, count in
            // Copy history
            for i in 0..<overlap {
                buffer[i] = history[i]
            }
            // Copy input
            for i in 0..<input.count {
                buffer[overlap + i] = input[i]
            }
            count = overlap + input.count
        }

        // Output count: number of decimated samples from the NEW input only
        let outputCount = input.count / decimationFactor
        guard outputCount > 0 else {
            // Save tail as new history
            saveHistory(from: extended)
            return []
        }

        var output = [Float](repeating: 0, count: outputCount)

        // vDSP_desamp: C[n] = sum_{p=0}^{P-1} A[n*DF + p] * F[p]
        // A starts at extended[0] so the first output uses all overlap samples
        extended.withUnsafeBufferPointer { ext in
            taps.withUnsafeBufferPointer { t in
                output.withUnsafeMutableBufferPointer { out in
                    let validOutputs = min(
                        outputCount,
                        max(0, (extended.count - numTaps) / decimationFactor + 1)
                    )
                    guard validOutputs > 0 else { return }
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

        // Save last (numTaps-1) samples from extended as history for next block
        saveHistory(from: extended)

        return output
    }

    private func saveHistory(from extended: [Float]) {
        let overlap = numTaps - 1
        if extended.count >= overlap {
            let start = extended.count - overlap
            history = Array(extended[start..<extended.count])
        } else {
            // Pad with zeros if not enough samples
            history = [Float](repeating: 0, count: overlap - extended.count) + extended
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
