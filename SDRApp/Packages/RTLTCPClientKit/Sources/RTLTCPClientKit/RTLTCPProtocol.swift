import Foundation

/// rtl_tcp protocol constants and command definitions.
public enum RTLTCPCommand: UInt8, Sendable {
    case setFrequency = 0x01
    case setSampleRate = 0x02
    case setGainMode = 0x03        // 0 = auto, 1 = manual
    case setGain = 0x04            // tenths of dB
    case setFrequencyCorrection = 0x05  // PPM
    case setIFGain = 0x06
    case setTestMode = 0x07
    case setAGCMode = 0x08
    case setDirectSampling = 0x09
    case setOffsetTuning = 0x0A
    case setRTLXtalFreq = 0x0B
    case setTunerXtalFreq = 0x0C
    case setTunerGainByIndex = 0x0D
    case setBiasTee = 0x0E

    /// Build a 5-byte command: 1 byte command + 4 bytes big-endian parameter.
    public func encode(parameter: UInt32) -> Data {
        var data = Data(capacity: 5)
        data.append(self.rawValue)
        var value = parameter.bigEndian
        data.append(Data(bytes: &value, count: 4))
        return data
    }
}

/// Direct sampling mode for RTL-SDR front-end bypass.
public enum DirectSamplingMode: UInt32, Sendable, Codable, CaseIterable {
    case off = 0
    case iBranch = 1
    case qBranch = 2
}

/// Parsed rtl_tcp initial header (12 bytes: magic "RTL0" + tuner type + gain count).
public struct RTLTCPHeader: Sendable, Equatable {
    public let magic: String
    public let tunerType: TunerType
    public let gainCount: UInt32

    public var isValid: Bool { magic == "RTL0" }

    public init?(data: Data) {
        guard data.count >= 12 else { return nil }

        let magicBytes = data.prefix(4)
        guard let magic = String(data: magicBytes, encoding: .ascii) else { return nil }
        self.magic = magic

        let tunerRaw = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        self.tunerType = TunerType(rawValue: tunerRaw) ?? .unknown

        self.gainCount = data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}

/// Known RTL-SDR tuner types.
public enum TunerType: UInt32, Sendable {
    case unknown = 0
    case e4000 = 1
    case fc0012 = 2
    case fc0013 = 3
    case fc2580 = 4
    case r820t = 5
    case r828d = 6

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .e4000: return "E4000"
        case .fc0012: return "FC0012"
        case .fc0013: return "FC0013"
        case .fc2580: return "FC2580"
        case .r820t: return "R820T"
        case .r828d: return "R828D"
        }
    }

    /// Capabilities inferred from tuner family.
    ///
    /// Notes:
    /// - `rtl_tcp` protocol does not expose a formal capabilities handshake.
    /// - We keep auto direct-sampling conservative to avoid enabling it on
    ///   setups where it is usually unavailable or undesirable.
    public var capabilities: TunerCapabilities {
        switch self {
        case .r820t, .r828d:
            return TunerCapabilities(
                supportsDirectSamplingAuto: true,
                supportsManualDirectSampling: true,
                supportsOffsetTuning: true,
                supportsBiasTeeControl: true
            )
        case .e4000, .fc0012, .fc0013, .fc2580:
            return TunerCapabilities(
                supportsDirectSamplingAuto: false,
                supportsManualDirectSampling: true,
                supportsOffsetTuning: true,
                supportsBiasTeeControl: false
            )
        case .unknown:
            return TunerCapabilities(
                supportsDirectSamplingAuto: false,
                supportsManualDirectSampling: true,
                supportsOffsetTuning: true,
                supportsBiasTeeControl: false
            )
        }
    }
}

/// Runtime tuner capability flags inferred from header tuner type.
public struct TunerCapabilities: Sendable, Equatable {
    public let supportsDirectSamplingAuto: Bool
    public let supportsManualDirectSampling: Bool
    public let supportsOffsetTuning: Bool
    public let supportsBiasTeeControl: Bool

    public init(
        supportsDirectSamplingAuto: Bool,
        supportsManualDirectSampling: Bool,
        supportsOffsetTuning: Bool,
        supportsBiasTeeControl: Bool
    ) {
        self.supportsDirectSamplingAuto = supportsDirectSamplingAuto
        self.supportsManualDirectSampling = supportsManualDirectSampling
        self.supportsOffsetTuning = supportsOffsetTuning
        self.supportsBiasTeeControl = supportsBiasTeeControl
    }
}
