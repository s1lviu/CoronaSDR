import Foundation
import Accelerate

/// Interleaved complex float buffer for DSP processing.
/// Stores I/Q samples as alternating Float pairs: [I0, Q0, I1, Q1, ...].
public final class ComplexBuffer {
    public var real: [Float]
    public var imag: [Float]
    public var count: Int { real.count }

    public init(capacity: Int) {
        real = [Float](repeating: 0, count: capacity)
        imag = [Float](repeating: 0, count: capacity)
    }

    public init(real: [Float], imag: [Float]) {
        precondition(real.count == imag.count)
        self.real = real
        self.imag = imag
    }

    /// Convert 8-bit unsigned IQ bytes to complex float.
    /// Input: [I0, Q0, I1, Q1, ...] where each byte is 0–255.
    /// Output: normalized to approximately -1.0...+1.0.
    public static func fromUInt8IQ(_ data: UnsafeRawBufferPointer, into buffer: ComplexBuffer) -> Int {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }

        // Ensure capacity
        if buffer.real.count < sampleCount {
            buffer.real = [Float](repeating: 0, count: sampleCount)
            buffer.imag = [Float](repeating: 0, count: sampleCount)
        }

        let bytes = data.bindMemory(to: UInt8.self)

        // Vectorized conversion: (byte - 128) / 128.0
        // First convert to float, then subtract 128 and scale
        buffer.real.withUnsafeMutableBufferPointer { realBuf in
            buffer.imag.withUnsafeMutableBufferPointer { imagBuf in
                for i in 0..<sampleCount {
                    realBuf[i] = (Float(bytes[i * 2]) - 127.5) / 127.5
                    imagBuf[i] = (Float(bytes[i * 2 + 1]) - 127.5) / 127.5
                }
            }
        }

        return sampleCount
    }

    /// Vectorized magnitude: sqrt(I^2 + Q^2) using Accelerate.
    public func magnitude(into output: inout [Float]) {
        let n = count
        if output.count < n { output = [Float](repeating: 0, count: n) }

        real.withUnsafeBufferPointer { r in
            imag.withUnsafeBufferPointer { i in
                output.withUnsafeMutableBufferPointer { out in
                    // Use vDSP for I^2 + Q^2
                    var realSq = [Float](repeating: 0, count: n)
                    var imagSq = [Float](repeating: 0, count: n)
                    vDSP_vsq(r.baseAddress!, 1, &realSq, 1, vDSP_Length(n))
                    vDSP_vsq(i.baseAddress!, 1, &imagSq, 1, vDSP_Length(n))
                    vDSP_vadd(realSq, 1, imagSq, 1, out.baseAddress!, 1, vDSP_Length(n))

                    // sqrt
                    var count = Int32(n)
                    vvsqrtf(out.baseAddress!, out.baseAddress!, &count)
                }
            }
        }
    }

    /// Vectorized power: I^2 + Q^2 (no sqrt, for FFT power spectrum).
    public func power(into output: inout [Float]) {
        let n = count
        if output.count < n { output = [Float](repeating: 0, count: n) }

        real.withUnsafeBufferPointer { r in
            imag.withUnsafeBufferPointer { i in
                output.withUnsafeMutableBufferPointer { out in
                    vDSP_vsq(r.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(n))
                    var imagSq = [Float](repeating: 0, count: n)
                    vDSP_vsq(i.baseAddress!, 1, &imagSq, 1, vDSP_Length(n))
                    vDSP_vadd(out.baseAddress!, 1, imagSq, 1, out.baseAddress!, 1, vDSP_Length(n))
                }
            }
        }
    }
}
