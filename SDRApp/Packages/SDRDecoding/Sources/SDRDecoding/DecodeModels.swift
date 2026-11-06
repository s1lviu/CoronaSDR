import Foundation

public enum DecodeMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off", cw = "CW", ft8 = "FT8"
    public var id: String { rawValue }
}

public struct FT8Message: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let payload: String
    public let audioHz: Float
    public let frequencyHz: Int
    public let receivedAt: Date
    public let samplePosition: Int64
    public let supported: Bool
    public let messageType: Int
}

public struct DecodeSnapshot: Sendable, Equatable {
    public var status = "Decoder off"
    public var lastWindowSummary: String?
    public var lastInterruption: String?
    public var progress: Double = 0
    public var transcript = ""
    public var estimatedWPM: Double?
    public var messages: [FT8Message] = []
    public var skippedWindows = 0
    public var decodeSeconds: Double = 0
    public init() {}
}

public struct DecoderConfiguration: Sendable, Equatable {
    public var mode: DecodeMode
    public var frequencyHz: Int
    public var pitchHz: Float
    public var speedWPM: Double
    public var automaticSpeed: Bool
    public init(mode: DecodeMode, frequencyHz: Int, pitchHz: Float = 600,
                speedWPM: Double = 20, automaticSpeed: Bool = true) {
        self.mode = mode; self.frequencyHz = frequencyHz
        self.pitchHz = pitchHz.isFinite ? min(1200, max(300, pitchHz)) : 600
        self.speedWPM = speedWPM.isFinite ? min(60, max(5, speedWPM)) : 20
        self.automaticSpeed = automaticSpeed
    }
}
