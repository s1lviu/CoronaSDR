import XCTest
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
}
