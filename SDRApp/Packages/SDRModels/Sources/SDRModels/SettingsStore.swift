import Foundation
import Observation

/// App-wide settings stored in UserDefaults.
@Observable
public final class SettingsStore {
    private let defaults: UserDefaults

    // MARK: - Onboarding

    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    // MARK: - Last Server

    public var lastServerHost: String {
        get { defaults.string(forKey: "lastServerHost") ?? "" }
        set { defaults.set(newValue, forKey: "lastServerHost") }
    }

    public var lastServerPort: Int {
        get { defaults.object(forKey: "lastServerPort") != nil ? defaults.integer(forKey: "lastServerPort") : 1234 }
        set { defaults.set(newValue, forKey: "lastServerPort") }
    }

    // MARK: - Radio Defaults

    public var lastFrequencyHz: Int {
        get { defaults.object(forKey: "lastFrequencyHz") != nil ? defaults.integer(forKey: "lastFrequencyHz") : 100_000_000 }
        set { defaults.set(newValue, forKey: "lastFrequencyHz") }
    }

    public var lastMode: String {
        get { defaults.string(forKey: "lastMode") ?? "WFM" }
        set { defaults.set(newValue, forKey: "lastMode") }
    }

    public var lastGainMode: String {
        get { defaults.string(forKey: "lastGainMode") ?? "Auto" }
        set { defaults.set(newValue, forKey: "lastGainMode") }
    }

    public var lastGainValue: Float {
        get { defaults.float(forKey: "lastGainValue") }
        set { defaults.set(newValue, forKey: "lastGainValue") }
    }

    public var lastPPM: Float {
        get { defaults.float(forKey: "lastPPM") }
        set { defaults.set(newValue, forKey: "lastPPM") }
    }

    // MARK: - Sample Profile

    public var selectedSampleProfileLabel: String {
        get { defaults.string(forKey: "selectedSampleProfileLabel") ?? "Low" }
        set { defaults.set(newValue, forKey: "selectedSampleProfileLabel") }
    }

    // MARK: - Display

    public var waterfallColorScheme: String {
        get { defaults.string(forKey: "waterfallColorScheme") ?? "classic" }
        set { defaults.set(newValue, forKey: "waterfallColorScheme") }
    }

    public var spectrumPeakHold: Bool {
        get { defaults.bool(forKey: "spectrumPeakHold") }
        set { defaults.set(newValue, forKey: "spectrumPeakHold") }
    }

    // MARK: - Audio

    public var deemphasis: Int {
        get { defaults.object(forKey: "deemphasis") != nil ? defaults.integer(forKey: "deemphasis") : 75 }
        set { defaults.set(newValue, forKey: "deemphasis") }
    }

    // MARK: - Debug

    public var debugLogsEnabled: Bool {
        get { defaults.bool(forKey: "debugLogsEnabled") }
        set { defaults.set(newValue, forKey: "debugLogsEnabled") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
}
