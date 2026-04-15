import XCTest
@testable import CoronaSDR
import RTLTCPClientKit
import SDRModels

final class RFControlsTests: XCTestCase {
    func testR820TCapabilitiesIncludeAutoDirectSamplingAndBiasTee() {
        let capabilities = TunerType.r820t.capabilities

        XCTAssertTrue(capabilities.supportsDirectSamplingAuto)
        XCTAssertTrue(capabilities.supportsManualDirectSampling)
        XCTAssertTrue(capabilities.supportsOffsetTuning)
        XCTAssertTrue(capabilities.supportsBiasTeeControl)
    }

    func testFC0012CapabilitiesDisableAutoAndBiasTee() {
        let capabilities = TunerType.fc0012.capabilities

        XCTAssertFalse(capabilities.supportsDirectSamplingAuto)
        XCTAssertTrue(capabilities.supportsManualDirectSampling)
        XCTAssertTrue(capabilities.supportsOffsetTuning)
        XCTAssertFalse(capabilities.supportsBiasTeeControl)
    }

    func testSettingsStorePersistsRFAndAudioToneControls() {
        let suiteName = "RFControlsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = SettingsStore(defaults: defaults)
        initial.directSamplingPreference = DirectSamplingPreference.qBranch.rawValue
        initial.isOffsetTuningEnabled = true
        initial.isBiasTeeEnabled = true
        initial.audioHighPassHz = 250
        initial.audioLowPassHz = 4_500

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.directSamplingPreference, DirectSamplingPreference.qBranch.rawValue)
        XCTAssertTrue(reloaded.isOffsetTuningEnabled)
        XCTAssertTrue(reloaded.isBiasTeeEnabled)
        XCTAssertEqual(reloaded.audioHighPassHz, 250)
        XCTAssertEqual(reloaded.audioLowPassHz, 4_500)
    }

    func testSoftwareOffsetTuningPlanMatchesRtlFmQuarterRateOffset() {
        let plan = ReceiverTuningPlan.make(
            requestedFrequencyHz: 100_000_000,
            sampleRateHz: 1_024_000,
            supportsHardwareOffsetTuning: true,
            hardwareOffsetTuningEnabled: false,
            directSamplingActive: false,
            maximumFrequencyHz: Int(UInt32.max)
        )

        XCTAssertEqual(plan.requestedFrequencyHz, 100_000_000)
        XCTAssertEqual(plan.tunerFrequencyHz, 100_256_000)
        XCTAssertEqual(plan.softwareFrequencyShiftHz, -256_000)
    }

    func testHardwareOffsetTuningDisablesSoftwareOffsetPlan() {
        let plan = ReceiverTuningPlan.make(
            requestedFrequencyHz: 100_000_000,
            sampleRateHz: 1_024_000,
            supportsHardwareOffsetTuning: true,
            hardwareOffsetTuningEnabled: true,
            directSamplingActive: false,
            maximumFrequencyHz: Int(UInt32.max)
        )

        XCTAssertEqual(plan.tunerFrequencyHz, 100_000_000)
        XCTAssertEqual(plan.softwareFrequencyShiftHz, 0)
    }

    func testDirectSamplingDisablesSoftwareOffsetPlan() {
        let plan = ReceiverTuningPlan.make(
            requestedFrequencyHz: 7_100_000,
            sampleRateHz: 250_000,
            supportsHardwareOffsetTuning: true,
            hardwareOffsetTuningEnabled: false,
            directSamplingActive: true,
            maximumFrequencyHz: Int(UInt32.max)
        )

        XCTAssertEqual(plan.tunerFrequencyHz, 7_100_000)
        XCTAssertEqual(plan.softwareFrequencyShiftHz, 0)
    }

    func testSoftwareOffsetPlanClampsNearMaximumTunableFrequency() {
        let maxFrequency = Int(UInt32.max)
        let plan = ReceiverTuningPlan.make(
            requestedFrequencyHz: maxFrequency - 10_000,
            sampleRateHz: 1_024_000,
            supportsHardwareOffsetTuning: true,
            hardwareOffsetTuningEnabled: false,
            directSamplingActive: false,
            maximumFrequencyHz: maxFrequency
        )

        XCTAssertEqual(plan.tunerFrequencyHz, maxFrequency)
        XCTAssertEqual(plan.softwareFrequencyShiftHz, -10_000)
    }
}
