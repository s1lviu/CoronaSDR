import Foundation
import CLiquidDSP

/// High-quality fractional resampler using liquid-dsp (Polyphase FIR).
/// Supports dynamic ratio adjustment for clock drift compensation.
public final class Resampler {
    private var q: resamp_rrrf?
    private var _ratio: Float
    private var outputScratch: [Float] = []

    /// Current resampling ratio (output_rate / input_rate).
    /// Adjusting this value updates the underlying liquid-dsp object instantly.
    public var currentRatio: Double {
        get { Double(_ratio) }
        set {
            let newRatio = Float(newValue)
            if abs(newRatio - _ratio) > 0.000001 {
                _ratio = newRatio
                if let q = q {
                    resamp_rrrf_set_rate(q, _ratio)
                }
            }
        }
    }

    /// Create a resampler.
    /// - Parameter ratio: output_rate / input_rate.
    public init(ratio: Double) {
        self._ratio = Float(ratio)

        // m: semi-length of filter (delay). 13 is a good balance for audio quality.
        // fc: cutoff frequency. 0.49 to avoid aliasing near Nyquist.
        // as: stop-band attenuation. 60dB is decent for SDR audio.
        // npfb: number of polyphase filter banks. 32 is standard.
        self.q = resamp_rrrf_create(_ratio, 13, 0.49, 60.0, 32)
    }

    /// Convenience: create from input and output sample rates.
    public convenience init(inputRate: Double, outputRate: Double) {
        self.init(ratio: outputRate / inputRate)
    }

    deinit {
        if let q = q {
            resamp_rrrf_destroy(q)
        }
    }

    /// Resample a block of input samples.
    /// Returns the resampled output array.
    public func process(_ input: [Float]) -> [Float] {
        var output: [Float] = []
        _ = process(input, into: &output)
        return output
    }

    /// Allocation-aware path: writes resampled audio into caller-provided storage.
    /// Returns number of valid output samples.
    @discardableResult
    public func process(_ input: [Float], into output: inout [Float]) -> Int {
        guard !input.isEmpty, let q = q else {
            output.removeAll(keepingCapacity: true)
            return 0
        }

        let maxNeeded = max(1, Int(resamp_rrrf_get_num_output(q, UInt32(input.count))))
        if outputScratch.count < maxNeeded {
            outputScratch = [Float](repeating: 0, count: maxNeeded)
        }

        var numWritten: UInt32 = 0
        input.withUnsafeBufferPointer { inBuf in
            outputScratch.withUnsafeMutableBufferPointer { outBuf in
                _ = resamp_rrrf_execute_block(
                    q,
                    UnsafeMutablePointer(mutating: inBuf.baseAddress!),
                    UInt32(input.count),
                    outBuf.baseAddress!,
                    &numWritten
                )
            }
        }

        let written = Int(numWritten)
        if written <= 0 {
            output.removeAll(keepingCapacity: true)
            return 0
        }

        if output.count != written {
            output = [Float](repeating: 0, count: written)
        }
        output.withUnsafeMutableBufferPointer { dest in
            outputScratch.withUnsafeBufferPointer { scratch in
                dest.baseAddress!.update(from: scratch.baseAddress!, count: written)
            }
        }

        return written
    }

    public func reset() {
        if let q = q {
            resamp_rrrf_reset(q)
        }
    }
}

/// PI controller for clock drift compensation.
/// Adjusts the resampler ratio to keep the audio ring buffer at a target fill level.
public final class DriftCompensator {
    private let targetFill: Double // e.g. 0.5
    private let kp: Double // proportional gain
    private let ki: Double // integral gain
    private let maxPPMAdjust: Double // max adjustment in PPM
    private var integral: Double = 0
    private let baseRatio: Double

    public init(
        baseRatio: Double,
        targetFill: Double = 0.5,
        kp: Double = 0.00001,
        ki: Double = 0.0000001,
        maxPPMAdjust: Double = 150
    ) {
        self.baseRatio = baseRatio
        self.targetFill = targetFill
        self.kp = kp
        self.ki = ki
        self.maxPPMAdjust = maxPPMAdjust
    }

    /// Update the drift compensator and return the adjusted resampler ratio.
    /// - Parameter currentFill: Current audio ring buffer fill level (0.0–1.0).
    /// - Returns: Adjusted resampler ratio.
    public func update(currentFill: Double) -> Double {
        let error = currentFill - targetFill

        integral += error
        // Anti-windup
        let maxIntegral = maxPPMAdjust / (ki * 1_000_000)
        integral = max(-maxIntegral, min(maxIntegral, integral))

        let correction = kp * error + ki * integral
        let maxCorrection = maxPPMAdjust / 1_000_000.0

        let clampedCorrection = max(-maxCorrection, min(maxCorrection, correction))
        // Negative correction: buffer too empty → need MORE output → increase ratio
        // Positive correction: buffer too full → need LESS output → decrease ratio
        return baseRatio * (1.0 - clampedCorrection)
    }

    public func reset() {
        integral = 0
    }
}
