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

    public var lastStepHz: Int {
        didSet { defaults.set(lastStepHz, forKey: "lastStepHz") }
    }

    public var lastBandwidthHz: Int {
        didSet { defaults.set(lastBandwidthHz, forKey: "lastBandwidthHz") }
    }

    public var lastSquelchLevel: Float {
        didSet { defaults.set(lastSquelchLevel, forKey: "lastSquelchLevel") }
    }

    public var lastBFOOffset: Float {
        didSet { defaults.set(lastBFOOffset, forKey: "lastBFOOffset") }
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

    // MARK: - RF Controls

    public var directSamplingPreference: String {
        didSet { defaults.set(directSamplingPreference, forKey: "directSamplingPreference") }
    }

    public var isOffsetTuningEnabled: Bool {
        didSet { defaults.set(isOffsetTuningEnabled, forKey: "isOffsetTuningEnabled") }
    }

    public var isBiasTeeEnabled: Bool {
        didSet { defaults.set(isBiasTeeEnabled, forKey: "isBiasTeeEnabled") }
    }

    // MARK: - Sample Profile

    public var selectedSampleProfileLabel: String {
        didSet { defaults.set(selectedSampleProfileLabel, forKey: "selectedSampleProfileLabel") }
    }

    // MARK: - Last Range Scan

    public var lastRangeScanStartMHz: String {
        didSet { defaults.set(lastRangeScanStartMHz, forKey: "lastRangeScanStartMHz") }
    }

    public var lastRangeScanEndMHz: String {
        didSet { defaults.set(lastRangeScanEndMHz, forKey: "lastRangeScanEndMHz") }
    }

    public var lastRangeScanStepKHz: String {
        didSet { defaults.set(lastRangeScanStepKHz, forKey: "lastRangeScanStepKHz") }
    }

    public var lastRangeScanMode: String {
        didSet { defaults.set(lastRangeScanMode, forKey: "lastRangeScanMode") }
    }

    // MARK: - Display

    public var waterfallColorScheme: String {
        didSet { defaults.set(waterfallColorScheme, forKey: "waterfallColorScheme") }
    }

    // MARK: - Audio

    public var deemphasis: Int {
        didSet { defaults.set(deemphasis, forKey: "deemphasis") }
    }

    public var audioHighPassHz: Int {
        didSet { defaults.set(audioHighPassHz, forKey: "audioHighPassHz") }
    }

    public var audioLowPassHz: Int {
        didSet { defaults.set(audioLowPassHz, forKey: "audioLowPassHz") }
    }

    public var noiseBlankerThreshold: Float {
        didSet { defaults.set(noiseBlankerThreshold, forKey: "noiseBlankerThreshold") }
    }

    public var audioAgcEnabled: Bool {
        didSet { defaults.set(audioAgcEnabled, forKey: "audioAgcEnabled") }
    }

    public var wfmStereoEnabled: Bool {
        didSet { defaults.set(wfmStereoEnabled, forKey: "wfmStereoEnabled") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        self.lastServerHost = defaults.string(forKey: "lastServerHost") ?? ""
        self.lastServerPort = defaults.object(forKey: "lastServerPort") != nil ? defaults.integer(forKey: "lastServerPort") : 1234
        self.lastFrequencyHz = defaults.object(forKey: "lastFrequencyHz") != nil ? defaults.integer(forKey: "lastFrequencyHz") : 100_000_000
        self.lastMode = defaults.string(forKey: "lastMode") ?? "WFM"
        self.lastStepHz = defaults.object(forKey: "lastStepHz") != nil ? defaults.integer(forKey: "lastStepHz") : 100_000
        self.lastBandwidthHz = defaults.object(forKey: "lastBandwidthHz") != nil ? defaults.integer(forKey: "lastBandwidthHz") : 200_000
        self.lastSquelchLevel = defaults.object(forKey: "lastSquelchLevel") != nil ? defaults.float(forKey: "lastSquelchLevel") : 0
        self.lastBFOOffset = defaults.object(forKey: "lastBFOOffset") != nil ? defaults.float(forKey: "lastBFOOffset") : 0
        self.lastGainMode = defaults.string(forKey: "lastGainMode") ?? "Auto"
        self.lastGainValue = defaults.float(forKey: "lastGainValue")
        self.lastPPM = defaults.float(forKey: "lastPPM")
        self.directSamplingPreference = defaults.string(forKey: "directSamplingPreference") ?? "Auto"
        self.isOffsetTuningEnabled = defaults.bool(forKey: "isOffsetTuningEnabled")
        self.isBiasTeeEnabled = defaults.bool(forKey: "isBiasTeeEnabled")
        self.selectedSampleProfileLabel = defaults.string(forKey: "selectedSampleProfileLabel") ?? "Low"
        self.lastRangeScanStartMHz = defaults.string(forKey: "lastRangeScanStartMHz") ?? "118.000"
        self.lastRangeScanEndMHz = defaults.string(forKey: "lastRangeScanEndMHz") ?? "137.000"
        self.lastRangeScanStepKHz = defaults.string(forKey: "lastRangeScanStepKHz") ?? "25"
        self.lastRangeScanMode = defaults.string(forKey: "lastRangeScanMode") ?? "NFM"
        self.waterfallColorScheme = defaults.string(forKey: "waterfallColorScheme") ?? "classic"
        self.deemphasis = defaults.object(forKey: "deemphasis") != nil ? defaults.integer(forKey: "deemphasis") : 75
        self.audioHighPassHz = defaults.object(forKey: "audioHighPassHz") != nil ? defaults.integer(forKey: "audioHighPassHz") : 0
        self.audioLowPassHz = defaults.object(forKey: "audioLowPassHz") != nil ? defaults.integer(forKey: "audioLowPassHz") : 0
        self.noiseBlankerThreshold = defaults.object(forKey: "noiseBlankerThreshold") != nil ? defaults.float(forKey: "noiseBlankerThreshold") : 0
        self.audioAgcEnabled = defaults.bool(forKey: "audioAgcEnabled")
        self.wfmStereoEnabled = defaults.object(forKey: "wfmStereoEnabled") != nil ? defaults.bool(forKey: "wfmStereoEnabled") : true
    }
}
