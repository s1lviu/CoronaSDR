import Foundation
import Accelerate

/// Numerically Controlled Oscillator for frequency shifting (mixing to baseband).
/// Pure Swift implementation using Accelerate for vectorized sine/cosine.
public final class NCOMixer {
    private var phase: Float = 0
    private var phaseIncrement: Float = 0
    private let twoPi: Float = 2.0 * .pi
    private var cosOut: [Float] = []
    private var sinOut: [Float] = []
    private var phases: [Float] = []
    private var temp: [Float] = []
    private var newReal: [Float] = []
    private var newImag: [Float] = []

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
        ensureCapacity(count)

        // Build phase ramp
        for i in 0..<count {
            phases[i] = phase + Float(i) * phaseIncrement
        }

        // Vectorized sin/cos
        var n = Int32(count)
        cosOut.withUnsafeMutableBufferPointer { cosPtr in
            phases.withUnsafeMutableBufferPointer { phasePtr in
                vvcosf(cosPtr.baseAddress!, phasePtr.baseAddress!, &n)
            }
        }
        sinOut.withUnsafeMutableBufferPointer { sinPtr in
            phases.withUnsafeMutableBufferPointer { phasePtr in
                vvsinf(sinPtr.baseAddress!, phasePtr.baseAddress!, &n)
            }
        }

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

    private func ensureCapacity(_ count: Int) {
        if cosOut.count < count { cosOut = [Float](repeating: 0, count: count) }
        if sinOut.count < count { sinOut = [Float](repeating: 0, count: count) }
        if phases.count < count { phases = [Float](repeating: 0, count: count) }
        if temp.count < count { temp = [Float](repeating: 0, count: count) }
        if newReal.count < count { newReal = [Float](repeating: 0, count: count) }
        if newImag.count < count { newImag = [Float](repeating: 0, count: count) }
    }
}
