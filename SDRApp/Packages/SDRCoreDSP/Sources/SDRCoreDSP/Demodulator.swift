import Foundation

/// Protocol for all demodulators.
public protocol Demodulator {
    /// Demodulate complex IQ samples into real audio samples.
    func demodulate(real: [Float], imag: [Float]) -> [Float]
    func reset()
}
