import Accelerate

/// Utilities for click-free audio transitions.
public enum AudioFade {
    /// Apply a linear fade-in to the buffer in-place.
    /// - Parameters:
    ///   - buffer: Audio samples to modify.
    ///   - fadeSamples: Number of samples over which to fade (e.g. 480 for 10ms at 48kHz).
    public static func fadeIn(_ buffer: UnsafeMutableBufferPointer<Float>, fadeSamples: Int) {
        applyFadeIn(buffer, fadeSamples: fadeSamples)
    }

    /// Apply fade-in by multiplying first `fadeSamples` samples with a linear ramp.
    public static func applyFadeIn(_ buffer: UnsafeMutableBufferPointer<Float>, fadeSamples: Int) {
        let count = min(fadeSamples, buffer.count)
        guard count > 0 else { return }

        let ramp = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        defer { ramp.deallocate() }

        var start: Float = 0
        var step: Float = 1.0 / Float(count)
        vDSP_vramp(&start, &step, ramp.baseAddress!, 1, vDSP_Length(count))

        vDSP_vmul(buffer.baseAddress!, 1, ramp.baseAddress!, 1, buffer.baseAddress!, 1, vDSP_Length(count))
    }

    /// Apply fade-out by multiplying last `fadeSamples` samples with a linear ramp.
    public static func applyFadeOut(_ buffer: UnsafeMutableBufferPointer<Float>, fadeSamples: Int) {
        let count = min(fadeSamples, buffer.count)
        guard count > 0 else { return }

        let offset = buffer.count - count

        let ramp = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        defer { ramp.deallocate() }

        var start: Float = 1.0
        var step: Float = -1.0 / Float(count)
        vDSP_vramp(&start, &step, ramp.baseAddress!, 1, vDSP_Length(count))

        vDSP_vmul(
            buffer.baseAddress!.advanced(by: offset), 1,
            ramp.baseAddress!, 1,
            buffer.baseAddress!.advanced(by: offset), 1,
            vDSP_Length(count)
        )
    }

    /// Number of samples for a given fade duration at 48kHz.
    public static func fadeSamples(durationMs: Double, sampleRate: Double = 48000) -> Int {
        Int(durationMs / 1000.0 * sampleRate)
    }
}
