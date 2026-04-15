import Foundation

public struct ChannelFilterDesign: Equatable {
    public let inputSampleRate: Int
    public let bandwidthHz: Int
    public let cutoffHz: Int
    public let intermediateTargetHz: Int
    public let decimationFactor: Int
    public let intermediateRate: Double
    public let normalizedCutoff: Float
    public let tapCount: Int
}

public enum ChannelFilterDesigner {
    private static let minimumInputSampleRate = 192_000
    private static let minimumBandwidthHz = 200
    private static let minimumNormalizedCutoff: Float = 0.0005
    private static let maximumNormalizedCutoff: Float = 0.99

    // Conservative Hamming-window transition width, normalized to Nyquist.
    // This keeps the designed transition band below the first alias boundary
    // before integer decimation.
    private static let hammingTransitionWidth: Double = 4.0

    public static func make(
        inputSampleRate: Int,
        bandwidthHz: Int,
        intermediateTargetHz: Int,
        cutoffHz requestedCutoffHz: Int? = nil
    ) -> ChannelFilterDesign {
        let sampleRate = max(minimumInputSampleRate, inputSampleRate)
        let bandwidth = max(minimumBandwidthHz, bandwidthHz)
        let cutoffHz = max(minimumBandwidthHz, requestedCutoffHz ?? bandwidth)
        let target = max(1, intermediateTargetHz)
        let decimationFactor = max(1, sampleRate / target)
        let intermediateRate = Double(sampleRate) / Double(decimationFactor)
        let cutoff = Float(cutoffHz) / Float(sampleRate)
        let normalizedCutoff = min(maximumNormalizedCutoff, max(minimumNormalizedCutoff, cutoff * 2))
        let tapCount = makeOdd(
            max(
                baseTapCount(forCutoffHz: cutoffHz),
                transitionLimitedTapCount(
                    sampleRate: sampleRate,
                    cutoffHz: cutoffHz,
                    decimationFactor: decimationFactor
                )
            )
        )

        return ChannelFilterDesign(
            inputSampleRate: sampleRate,
            bandwidthHz: bandwidth,
            cutoffHz: cutoffHz,
            intermediateTargetHz: target,
            decimationFactor: decimationFactor,
            intermediateRate: intermediateRate,
            normalizedCutoff: normalizedCutoff,
            tapCount: tapCount
        )
    }

    private static func baseTapCount(forCutoffHz cutoffHz: Int) -> Int {
        if cutoffHz < 5_000 {
            return 127
        } else if cutoffHz < 50_000 {
            return 63
        } else {
            return 65
        }
    }

    private static func transitionLimitedTapCount(
        sampleRate: Int,
        cutoffHz: Int,
        decimationFactor: Int
    ) -> Int {
        guard decimationFactor > 1 else { return 1 }

        let inputNyquist = Double(sampleRate) / 2.0
        let decimatedNyquist = Double(sampleRate) / Double(decimationFactor) / 2.0
        let transitionHz = decimatedNyquist - Double(cutoffHz)
        guard transitionHz > 0 else {
            return 1
        }

        let normalizedTransition = transitionHz / inputNyquist
        guard normalizedTransition > 0 else {
            return 1
        }

        return Int(ceil(hammingTransitionWidth / normalizedTransition))
    }

    private static func makeOdd(_ value: Int) -> Int {
        value | 1
    }
}
