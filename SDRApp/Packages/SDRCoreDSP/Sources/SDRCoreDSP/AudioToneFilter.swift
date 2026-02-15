import Foundation

/// Lightweight audio tone shaping chain with optional high-pass and low-pass filters.
///
/// Designed for realtime DSP loop usage:
/// - In-place processing
/// - No allocations in hot path
/// - Stable one-pole filters with persistent state
public final class AudioToneFilter {
    private let sampleRate: Float
    private let lock = NSLock()

    private var highPassCutoffHz: Float = 0
    private var lowPassCutoffHz: Float = 0

    private var highPassAlpha: Float = 0
    private var lowPassAlpha: Float = 0

    private var hpPrevInput: Float = 0
    private var hpPrevOutput: Float = 0
    private var lpPrevOutput: Float = 0

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
        updateCoefficientsLocked()
    }

    public func setHighPassCutoff(_ hz: Int) {
        lock.lock()
        defer { lock.unlock() }
        highPassCutoffHz = max(0, Float(hz))
        updateCoefficientsLocked()
    }

    public func setLowPassCutoff(_ hz: Int) {
        lock.lock()
        defer { lock.unlock() }
        lowPassCutoffHz = max(0, Float(hz))
        updateCoefficientsLocked()
    }

    public func currentHighPassCutoffHz() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(highPassCutoffHz.rounded())
    }

    public func currentLowPassCutoffHz() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(lowPassCutoffHz.rounded())
    }

    public func processInPlace(_ samples: UnsafeMutableBufferPointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return }
        guard let base = samples.baseAddress else { return }

        let hpEnabled = highPassCutoffHz > 0
        let lpEnabled = lowPassCutoffHz > 0
        if !hpEnabled, !lpEnabled { return }

        var hpX1 = hpPrevInput
        var hpY1 = hpPrevOutput
        var lpY1 = lpPrevOutput
        let hpA = highPassAlpha
        let lpA = lowPassAlpha

        for i in 0..<count {
            let input = base[i]
            var y = input

            if hpEnabled {
                y = hpA * (hpY1 + input - hpX1)
                hpX1 = input
                hpY1 = y
            }

            if lpEnabled {
                lpY1 = lpY1 + lpA * (y - lpY1)
                y = lpY1
            }

            base[i] = y
        }

        hpPrevInput = hpX1
        hpPrevOutput = hpY1
        lpPrevOutput = lpY1
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        hpPrevInput = 0
        hpPrevOutput = 0
        lpPrevOutput = 0
    }

    private func updateCoefficientsLocked() {
        // High-pass (one-pole): y[n] = a * (y[n-1] + x[n] - x[n-1])
        if highPassCutoffHz > 0 {
            let ratio = (2 * Float.pi * highPassCutoffHz) / sampleRate
            highPassAlpha = 1 / (1 + ratio)
        } else {
            highPassAlpha = 0
        }

        // Low-pass (one-pole): y[n] = y[n-1] + a * (x[n] - y[n-1])
        if lowPassCutoffHz > 0 {
            lowPassAlpha = 1 - exp(-2 * Float.pi * lowPassCutoffHz / sampleRate)
        } else {
            lowPassAlpha = 0
        }
    }
}
