import Foundation
import SwiftData

@Model
public final class RangeScanPreset {
    public var id: UUID
    public var name: String
    public var startHz: Int
    public var endHz: Int
    public var stepHz: Int
    public var modeRaw: String
    public var createdAt: Date

    public var mode: DemodMode {
        get { DemodMode(rawValue: modeRaw) ?? .nfm }
        set { modeRaw = newValue.rawValue }
    }

    public init(
        name: String,
        startHz: Int,
        endHz: Int,
        stepHz: Int,
        mode: DemodMode
    ) {
        self.id = UUID()
        self.name = name
        self.startHz = startHz
        self.endHz = endHz
        self.stepHz = stepHz
        self.modeRaw = mode.rawValue
        self.createdAt = Date()
    }
}
