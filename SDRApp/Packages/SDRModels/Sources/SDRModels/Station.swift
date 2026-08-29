import Foundation
import SwiftData

@Model
public final class Station {
    public var id: UUID
    public var name: String
    public var frequencyHz: Int
    public var modeRaw: String
    public var bandwidthHz: Int
    public var stepHz: Int
    public var squelch: Float
    public var gainModeRaw: String
    public var gainValue: Float
    public var ppm: Float
    @Relationship(inverse: \Tag.stations)
    public var tags: [Tag]
    public var lastUsedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var mode: DemodMode {
        get { DemodMode(rawValue: modeRaw) ?? .nfm }
        set { modeRaw = newValue.rawValue }
    }

    public var gainMode: GainMode {
        get { GainMode(rawValue: gainModeRaw) ?? .auto }
        set { gainModeRaw = newValue.rawValue }
    }

    public init(
        name: String,
        frequencyHz: Int,
        mode: DemodMode = .nfm,
        bandwidthHz: Int? = nil,
        stepHz: Int? = nil,
        squelch: Float = 0,
        gainMode: GainMode = .auto,
        gainValue: Float = 0,
        ppm: Float = 0,
        tags: [Tag] = []
    ) {
        self.id = UUID()
        self.name = name
        self.frequencyHz = frequencyHz
        self.modeRaw = mode.rawValue
        self.bandwidthHz = bandwidthHz ?? mode.defaultBandwidthHz
        self.stepHz = stepHz ?? mode.defaultStepHz
        self.squelch = squelch
        self.gainModeRaw = gainMode.rawValue
        self.gainValue = gainValue
        self.ppm = ppm
        self.tags = tags
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
