import XCTest
@testable import CoronaSDR

@MainActor
final class DecoderControlsTests: XCTestCase {
    func testDecoderProfilesRestoreReceiverAndMute() {
        let radio = RadioViewModel()
        radio.setMode(.nfm); radio.setBandwidth(10000); radio.stepHz = 6250
        radio.setDecoderMode(.ft8)
        XCTAssertEqual(radio.mode, .usb)
        XCTAssertEqual(radio.bandwidthHz,3500)
        XCTAssertEqual(radio.bfoOffset,0)
        XCTAssertEqual(radio.decodeState.snapshot.status,"Connect a receiver to decode")
        radio.setDecoderMode(.cw)
        XCTAssertEqual(radio.mode,.cw)
        XCTAssertEqual(radio.bandwidthHz,500)
        XCTAssertEqual(radio.bfoOffset,600)
        radio.setMonitorMuted(true)
        radio.setDecoderMode(.off)
        XCTAssertEqual(radio.mode,.nfm)
        XCTAssertEqual(radio.bandwidthHz,10000)
        XCTAssertEqual(radio.stepHz,6250)
        XCTAssertFalse(radio.decodeState.monitorMuted)
    }
    func testManualChangesAreNotOverwrittenOnExit() {
        let radio = RadioViewModel()
        radio.setDecoderMode(.cw)
        radio.setBandwidth(700)
        radio.setBFOOffset(1000)
        radio.setDecoderMode(.off)
        XCTAssertEqual(radio.mode,.cw)
        XCTAssertEqual(radio.bandwidthHz,700)
        XCTAssertEqual(radio.bfoOffset,1000)
    }
    func testIncompatibleReceiverChangesStopFT8() {
        let radio = RadioViewModel()
        radio.setDecoderMode(.ft8); radio.setBandwidth(2400)
        XCTAssertEqual(radio.decodeState.mode,.off)
        radio.setDecoderMode(.ft8); radio.setMode(.am)
        XCTAssertEqual(radio.decodeState.mode,.off)
        XCTAssertEqual(radio.mode,.am)
    }
    func testReselectingModePreservesActualReceiveSettingsUntilDecoderAppliesProfile() {
        let radio = RadioViewModel()
        radio.setMode(.cw); radio.setBandwidth(700); radio.stepHz = 25
        radio.setMode(.cw)
        XCTAssertEqual(radio.bandwidthHz,700)
        XCTAssertEqual(radio.stepHz,25)
        radio.setDecoderMode(.cw)
        XCTAssertEqual(radio.bandwidthHz,500)
        radio.setDecoderMode(.off)
        XCTAssertEqual(radio.bandwidthHz,700)
        XCTAssertEqual(radio.stepHz,25)
    }
}
