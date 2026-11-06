import Foundation

/// Filter the selected RF carrier at baseband before adding a listening pitch.
public final class CWDemodulator: Demodulator {
    private let sampleRate: Float
    private let filterI: FIRFilter
    private let filterQ: FIRFilter
    private var phase: Float = 0
    public var pitchHz: Float = 600

    public init(sampleRate: Float = 48000, bandwidthHz: Int = 500) {
        precondition(sampleRate > 0)
        self.sampleRate = sampleRate
        let halfWidth = Float(max(200, min(2400, bandwidthHz))) / 2
        let taps = max(127, min(4095, Int(4 * sampleRate / max(150, halfWidth))) | 1)
        filterI = FIRFilter(cutoffNormalized: halfWidth * 2 / sampleRate, numTaps: taps)
        filterQ = FIRFilter(cutoffNormalized: halfWidth * 2 / sampleRate, numTaps: taps)
    }
    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        let i = filterI.process(real), q = filterQ.process(imag)
        let count = min(i.count, q.count)
        var output = [Float](repeating: 0, count: count)
        let pitch = pitchHz.isFinite ? min(1200, max(300, pitchHz)) : 600
        let increment = 2 * Float.pi * pitch / sampleRate
        for n in 0..<count {
            output[n] = i[n] * cos(phase) - q[n] * sin(phase)
            phase += increment
            if phase >= 2 * .pi { phase -= 2 * .pi }
        }
        return output
    }
    public func reset() { filterI.reset(); filterQ.reset(); phase = 0 }
}
