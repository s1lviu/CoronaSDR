import Foundation
import SwiftData

@Model
public final class SampleProfile {
    public var id: UUID
    public var label: String
    public var sampleRate: Int
    public var fftSize: Int
    public var uiFps: Int
    public var audioDecimationTarget: Int

    public init(
        label: String,
        sampleRate: Int,
        fftSize: Int,
        uiFps: Int,
        audioDecimationTarget: Int = 48000
    ) {
        self.id = UUID()
        self.label = label
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.uiFps = uiFps
        self.audioDecimationTarget = audioDecimationTarget
    }

    /// Default sample profiles: Low, Medium, High.
    public static func defaults() -> [SampleProfile] {
        [
            SampleProfile(label: "Low", sampleRate: 1_024_000, fftSize: 2048, uiFps: 15),
            SampleProfile(label: "Medium", sampleRate: 2_048_000, fftSize: 4096, uiFps: 20),
            SampleProfile(label: "High", sampleRate: 2_400_000, fftSize: 4096, uiFps: 30),
        ]
    }
}
