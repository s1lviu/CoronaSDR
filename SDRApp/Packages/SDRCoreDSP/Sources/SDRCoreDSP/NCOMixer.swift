import Foundation
import Accelerate

/// Numerically Controlled Oscillator for frequency shifting (mixing to baseband).
/// Pure Swift implementation using Accelerate for vectorized sine/cosine.
public final class NCOMixer {
    private var phase: Float = 0
    private var phaseIncrement: Float = 0
    private let twoPi: Float = 2.0 * .pi

    /// Set the NCO frequency.
    /// - Parameters:
    ///   - frequencyHz: Offset frequency in Hz (can be negative).
    ///   - sampleRate: Current sample rate in Hz.
    public func setFrequency(_ frequencyHz: Float, sampleRate: Float) {
        phaseIncrement = twoPi * frequencyHz / sampleRate
    }

    /// Mix complex IQ signal with NCO output (frequency shift).
    /// Multiplies input by exp(-j * 2π * f * t) for downconversion.
    public func mix(real: inout [Float], imag: inout [Float], count: Int) {
        precondition(real.count >= count && imag.count >= count)
        guard count > 0 else { return }

        var cosOut = [Float](repeating: 0, count: count)
        var sinOut = [Float](repeating: 0, count: count)
        var phases = [Float](repeating: 0, count: count)
        var temp = [Float](repeating: 0, count: count)
        var newReal = [Float](repeating: 0, count: count)
        var newImag = [Float](repeating: 0, count: count)

        // Build phase ramp
        for i in 0..<count {
            phases[i] = phase + Float(i) * phaseIncrement
        }

        // Vectorized sin/cos
        var n = Int32(count)
        vvcosf(&cosOut, &phases, &n)
        vvsinf(&sinOut, &phases, &n)

        // Complex multiply: (I + jQ) * (cos - jsin)
        // Result_I = I*cos + Q*sin
        // Result_Q = Q*cos - I*sin

        // newReal = I*cos + Q*sin
        vDSP_vmul(real, 1, cosOut, 1, &newReal, 1, vDSP_Length(count))
        vDSP_vmul(imag, 1, sinOut, 1, &temp, 1, vDSP_Length(count))
        vDSP_vadd(newReal, 1, temp, 1, &newReal, 1, vDSP_Length(count))

        // newImag = Q*cos - I*sin
        vDSP_vmul(imag, 1, cosOut, 1, &newImag, 1, vDSP_Length(count))
        vDSP_vmul(real, 1, sinOut, 1, &temp, 1, vDSP_Length(count))
        vDSP_vsub(temp, 1, newImag, 1, &newImag, 1, vDSP_Length(count))

        // Copy back
        real.withUnsafeMutableBufferPointer { r in
            newReal.withUnsafeBufferPointer { nr in
                r.baseAddress!.update(from: nr.baseAddress!, count: count)
            }
        }
        imag.withUnsafeMutableBufferPointer { i in
            newImag.withUnsafeBufferPointer { ni in
                i.baseAddress!.update(from: ni.baseAddress!, count: count)
            }
        }

        // Update phase, keeping it wrapped
        phase += Float(count) * phaseIncrement
        phase = phase.truncatingRemainder(dividingBy: twoPi)
    }

    public func reset() {
        phase = 0
    }
}
