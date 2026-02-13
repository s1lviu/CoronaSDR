import Foundation

/// Demodulation modes supported by the SDR.
public enum DemodMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case am = "AM"
    case nfm = "NFM"
    case wfm = "WFM"
    case usb = "USB"
    case lsb = "LSB"
    case cw = "CW"

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    /// Default bandwidth in Hz for this mode.
    public var defaultBandwidthHz: Int {
        switch self {
        case .am: return 10_000
        case .nfm: return 12_500
        case .wfm: return 200_000
        case .usb, .lsb: return 2_400
        case .cw: return 500
        }
    }

    /// Default step in Hz for this mode.
    public var defaultStepHz: Int {
        switch self {
        case .am: return 9_000
        case .nfm: return 12_500
        case .wfm: return 100_000
        case .usb, .lsb: return 1_000
        case .cw: return 100
        }
    }

    /// Whether this mode uses SSB-style BFO fine tuning.
    public var usesBFO: Bool {
        switch self {
        case .usb, .lsb, .cw: return true
        default: return false
        }
    }

    /// Whether squelch is applicable for this mode.
    public var supportsSquelch: Bool {
        switch self {
        case .am, .nfm: return true
        default: return false
        }
    }
}

/// Gain control mode.
public enum GainMode: String, Codable, CaseIterable, Sendable {
    case auto = "Auto"
    case manual = "Manual"
}

/// SDR server protocol type.
public enum SDRProtocol: String, Codable, CaseIterable, Sendable {
    case rtlTcp = "rtl_tcp"
    case hfpTcp = "hfp_tcp"
    case rspTcp = "rsp_tcp"
}

/// Reconnect policy after connection loss.
public enum ReconnectPolicy: String, Codable, CaseIterable, Sendable {
    case never = "Never"
    case exponentialBackoff = "Exponential Backoff"
    case immediate = "Immediate"
}
