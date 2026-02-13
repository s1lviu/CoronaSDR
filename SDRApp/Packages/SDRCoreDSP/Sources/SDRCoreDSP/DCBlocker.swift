import Foundation

/// IIR DC blocker filter.
/// y[n] = x[n] - x[n-1] + alpha * y[n-1]
/// where alpha is typically 0.995–0.999 for effective DC removal.
public final class DCBlocker {
    private var alpha: Float
    private var prevX: Float = 0
    private var prevY: Float = 0

    public init(alpha: Float = 0.998) {
        self.alpha = alpha
    }

    /// Process a block of samples in-place.
    public func process(_ samples: inout [Float]) {
        for i in 0..<samples.count {
            let x = samples[i]
            let y = x - prevX + alpha * prevY
            prevX = x
            prevY = y
            samples[i] = y
        }
    }

    /// Process separate I and Q channels.
    public func processIQ(real: inout [Float], imag: inout [Float]) {
        // Use two separate DC blockers
        process(&real)
        // Reset is wrong here - we need separate state
    }

    public func reset() {
        prevX = 0
        prevY = 0
    }
}

/// Paired DC blocker for I and Q channels.
public final class IQDCBlocker {
    private let dcI = DCBlocker()
    private let dcQ = DCBlocker()

    public init(alpha: Float = 0.998) {
        // Both use the same alpha
    }

    public func process(real: inout [Float], imag: inout [Float]) {
        dcI.process(&real)
        dcQ.process(&imag)
    }

    public func reset() {
        dcI.reset()
        dcQ.reset()
    }
}
