import Foundation

/// Continuous decoder clock, independent of the speaker's drift controller and audio effects.
public final class DecoderAudioPath {
    private let filter: FIRFilter
    private let resampler: Resampler
    private var filtered: [Float] = []

    public init(inputRate: Double) {
        precondition(inputRate >= 12000 && inputRate.isFinite)
        filter = FIRFilter(cutoffNormalized: Float(3800 * 2 / inputRate), numTaps: 257)
        resampler = Resampler(inputRate: inputRate, outputRate: 12000)
    }

    @discardableResult public func process(_ input: [Float], into output: inout [Float]) -> Int {
        filter.process(input, into: &filtered)
        return resampler.process(filtered, into: &output)
    }

    public func reset() { filter.reset(); resampler.reset() }
}
