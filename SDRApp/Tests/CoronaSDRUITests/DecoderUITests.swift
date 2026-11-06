import XCTest

@MainActor
final class DecoderUITests: XCTestCase {
    func testRecordedNetworkStreamDetailsSharingAndBackgroundStop() throws {
        continueAfterFailure = false
        let wav = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"191111_110130",withExtension:"wav"))
        let server = try RadioReplayServer(wav:wav)
        defer { server.stop() }
        let ready = expectation(description:"Loopback radio ready")
        server.start { _ in ready.fulfill() }
        wait(for:[ready], timeout:5)
        let port = try XCTUnwrap(server.port)
        let app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding","YES", "-lastServerHost","127.0.0.1",
                               "-lastServerPort",String(port), "-lastFrequencyHz","100000000",
                               "-isOffsetTuningEnabled","YES", "-directSamplingPreference","off",
                               "-selectedSampleProfileLabel","Ultra Low", "-lastMode","USB"]
        app.launch()
        let play = app.buttons["Play"]
        let connected = XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:play)
        wait(for:[connected], timeout:15)
        play.tap()
        let ft8 = app.segmentedControls["decoder.mode"].buttons["FT8"]
        for _ in 0..<8 where !ft8.isHittable { scrollPage(app, down:true) }
        selectMode("FT8", in: app)
        let mute = app.switches["Mute listening audio"]
        // Keep the full toggle away from the tab bar's scroll edge. Re-evaluate
        // direction because a large accessibility row can scroll past the viewport.
        for _ in 0..<10 {
            let frame = mute.frame
            print("Mute target frame: \(frame), hittable: \(mute.isHittable)")
            if frame.minY > 140 && frame.maxY < app.frame.height - 160 { break }
            scrollPage(app, down:frame.midY > app.frame.height / 2)
        }
        XCTAssertTrue(mute.isHittable)
        let muteScreen = XCTAttachment(screenshot:app.screenshot())
        muteScreen.name = "Mute before activation"; muteScreen.lifetime = .keepAlways; add(muteScreen)
        mute.tap()
        XCTAssertEqual(mute.value as? String, "1")
        let freeze = app.buttons["Freeze display"]
        for _ in 0..<8 where !freeze.isHittable { scrollPage(app, down:true) }
        let message = app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "Hz audio")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout:75), app.staticTexts["decoder.status"].label)
        XCTAssertTrue(server.received(command:2,value:250000))
        XCTAssertTrue(server.received(command:1,value:100000000))
        for _ in 0..<8 where !freeze.isHittable { scrollPage(app, down:true) }
        XCTAssertTrue(freeze.isHittable)
        freeze.tap()
        for _ in 0..<8 where !message.isHittable || message.frame.maxY > app.frame.height-140 {
            scrollPage(app, down:true)
        }
        XCTAssertTrue(message.isHittable)
        message.tap()
        XCTAssertTrue(app.navigationBars["FT8 reception"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Dial frequency"].exists)
        let details = XCTAttachment(screenshot:app.screenshot())
        details.name = "Recorded FT8 reception details"; details.lifetime = .keepAlways; add(details)
        app.buttons["Done"].tap()
        for _ in 0..<8 where !app.buttons["Share decoded text"].isHittable { scrollPage(app, down:false) }
        app.buttons["Share decoded text"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout:10))
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout:30))
        app.cells["Copy"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for:.runningBackground, timeout:5) || app.state == .runningBackgroundSuspended)
        app.activate()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout:5))
        for _ in 0..<8 where !ft8.isHittable { scrollPage(app, down:false) }
        XCTAssertFalse(app.buttons["Stop"].exists)
        for _ in 0..<8 where !app.buttons["Clear"].isHittable { scrollPage(app, down:true) }
        app.buttons["Clear"].tap()
        XCTAssertFalse(message.exists)
        XCTAssertFalse(app.buttons["Share decoded text"].isEnabled)
    }

    private func selectMode(_ mode: String, in app: XCUIApplication) {
        app.segmentedControls["decoder.mode"].buttons[mode].tap()
        if app.popovers.firstMatch.exists { app.popovers.buttons[mode].tap() }
    }

    // Stay inside the card's padding; the outer gutter does not receive scroll gestures.
    private func scrollPage(_ app: XCUIApplication, down: Bool, x: CGFloat = 18) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: down ? 0.75 : 0.25))
            .withOffset(CGVector(dx: x, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: down ? 0.25 : 0.75))
            .withOffset(CGVector(dx: x, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func testDecoderSelectionHelpAndAccessibleControls() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-hasCompletedOnboarding", "YES", "-lastServerHost", ""]
        app.launch()
        let layout = XCTAttachment(screenshot:app.screenshot())
        layout.name = "Radio layout"; layout.lifetime = .keepAlways; add(layout)
        let range = app.sliders["Waterfall dynamic range"]
        let spectrum = app.otherElements["Spectrum and Waterfall display"]
        let originalFrequency = app.buttons["radio.frequency"].label
        spectrum.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.5))
            .press(forDuration:0.05, thenDragTo:spectrum.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.5)))
        XCTAssertNotEqual(app.buttons["radio.frequency"].label, originalFrequency)
        let frequencyBeforeScrolling = app.buttons["radio.frequency"].label
        for _ in 0..<8 where !range.isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(range.isHittable)
        XCTAssertEqual(app.buttons["radio.frequency"].label, frequencyBeforeScrolling)
        let rangeScreen = XCTAttachment(screenshot:app.screenshot())
        rangeScreen.name = "Waterfall range controls"; rangeScreen.lifetime = .keepAlways; add(rangeScreen)
        let ft8 = app.segmentedControls["decoder.mode"].buttons["FT8"]
        for _ in 0..<5 where !ft8.isHittable { scrollPage(app, down: true) }
        XCTAssertTrue(ft8.waitForExistence(timeout:10))
        selectMode("FT8", in: app)
        XCTAssertTrue(app.staticTexts["decoder.status"].label.contains("Connect a receiver to decode"))
        XCTAssertTrue(app.switches["Mute listening audio"].exists)
        let ft8Screen = XCTAttachment(screenshot:app.screenshot())
        ft8Screen.name = "FT8 controls"; ft8Screen.lifetime = .keepAlways; add(ft8Screen)
        app.buttons["About CW and FT8 decoding"].tap()
        XCTAssertTrue(app.navigationBars["Decoding help"].waitForExistence(timeout:5))
        app.buttons["Done"].tap()
        let clear = app.buttons["Clear"]
        for _ in 0..<8 where !clear.isHittable { scrollPage(app, down: true) }
        XCTAssertTrue(clear.isHittable)
        app.buttons["Freeze display"].tap()
        XCTAssertTrue(app.buttons["Show live results"].exists)
        clear.tap()
        XCTAssertTrue(app.buttons["Freeze display"].exists)
        let resultsScreen = XCTAttachment(screenshot:app.screenshot())
        resultsScreen.name = "FT8 results area"; resultsScreen.lifetime = .keepAlways; add(resultsScreen)
        let cw = app.segmentedControls["decoder.mode"].buttons["CW"]
        for _ in 0..<8 where !cw.isHittable { scrollPage(app, down: false) }
        selectMode("CW", in: app)
        XCTAssertTrue(app.switches["Track sending speed"].exists)
        for _ in 0..<8 where !clear.isHittable { scrollPage(app, down: true) }
        XCTAssertTrue(clear.isHittable)
        XCTAssertTrue(app.staticTexts["Decoded Morse text appears here. □ marks an uncertain character."].exists)
        let cwScreen = XCTAttachment(screenshot:app.screenshot())
        cwScreen.name = "CW controls"; cwScreen.lifetime = .keepAlways; add(cwScreen)
        let off = app.segmentedControls["decoder.mode"].buttons["Off"]
        for _ in 0..<8 where !off.isHittable { scrollPage(app, down: false) }
        selectMode("Off", in: app)
        XCTAssertTrue(app.staticTexts["decoder.status"].label.contains("Decoder off"))
        let ppm = app.sliders["PPM correction"]
        for _ in 0..<10 where !ppm.isHittable { scrollPage(app, down:true) }
        XCTAssertTrue(ppm.isHittable)
        let receiver = XCTAttachment(screenshot:app.screenshot())
        receiver.name = "Receiver controls"; receiver.lifetime = .keepAlways; add(receiver)
    }
}
