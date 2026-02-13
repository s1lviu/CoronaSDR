import Foundation
import Observation

/// App-wide settings stored in UserDefaults.
@Observable
public final class SettingsStore {
    private let defaults: UserDefaults

    // MARK: - Onboarding

    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    // MARK: - Last Server

    public var lastServerHost: String {
        didSet { defaults.set(lastServerHost, forKey: "lastServerHost") }
    }

    public var lastServerPort: Int {
        didSet { defaults.set(lastServerPort, forKey: "lastServerPort") }
    }

    // MARK: - Radio Defaults

    public var lastFrequencyHz: Int {
        didSet { defaults.set(lastFrequencyHz, forKey: "lastFrequencyHz") }
    }

    public var lastMode: String {
        didSet { defaults.set(lastMode, forKey: "lastMode") }
    }

    public var lastGainMode: String {
        didSet { defaults.set(lastGainMode, forKey: "lastGainMode") }
    }

    public var lastGainValue: Float {
        didSet { defaults.set(lastGainValue, forKey: "lastGainValue") }
    }

    public var lastPPM: Float {
        didSet { defaults.set(lastPPM, forKey: "lastPPM") }
    }

    // MARK: - Sample Profile

    public var selectedSampleProfileLabel: String {
        didSet { defaults.set(selectedSampleProfileLabel, forKey: "selectedSampleProfileLabel") }
    }

    // MARK: - Display

    public var waterfallColorScheme: String {
        didSet { defaults.set(waterfallColorScheme, forKey: "waterfallColorScheme") }
    }

    public var spectrumPeakHold: Bool {
        didSet { defaults.set(spectrumPeakHold, forKey: "spectrumPeakHold") }
    }

    // MARK: - Audio

    public var deemphasis: Int {
        didSet { defaults.set(deemphasis, forKey: "deemphasis") }
    }

    // MARK: - Debug

    public var debugLogsEnabled: Bool {
        didSet { defaults.set(debugLogsEnabled, forKey: "debugLogsEnabled") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        self.lastServerHost = defaults.string(forKey: "lastServerHost") ?? ""
        self.lastServerPort = defaults.object(forKey: "lastServerPort") != nil ? defaults.integer(forKey: "lastServerPort") : 1234
        self.lastFrequencyHz = defaults.object(forKey: "lastFrequencyHz") != nil ? defaults.integer(forKey: "lastFrequencyHz") : 100_000_000
        self.lastMode = defaults.string(forKey: "lastMode") ?? "WFM"
        self.lastGainMode = defaults.string(forKey: "lastGainMode") ?? "Auto"
        self.lastGainValue = defaults.float(forKey: "lastGainValue")
        self.lastPPM = defaults.float(forKey: "lastPPM")
        self.selectedSampleProfileLabel = defaults.string(forKey: "selectedSampleProfileLabel") ?? "Low"
        self.waterfallColorScheme = defaults.string(forKey: "waterfallColorScheme") ?? "classic"
        self.spectrumPeakHold = defaults.bool(forKey: "spectrumPeakHold")
        self.deemphasis = defaults.object(forKey: "deemphasis") != nil ? defaults.integer(forKey: "deemphasis") : 75
        self.debugLogsEnabled = defaults.bool(forKey: "debugLogsEnabled")
    }
}
