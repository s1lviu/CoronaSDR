import XCTest
import SDRModels
@testable import CoronaSDR

final class DeepLinkHandlerTests: XCTestCase {
    func testParseTuneWithModeIsCaseInsensitive() {
        let url = URL(string: "coronasdr://tune?freq=100000000&mode=wfm")!
        let action = DeepLinkHandler.parse(url: url)

        XCTAssertEqual(
            action,
            .tune(frequencyHz: 100_000_000, mode: .wfm)
        )
    }

    func testParseStartAndStop() {
        XCTAssertEqual(DeepLinkHandler.parse(url: URL(string: "coronasdr://start")!), .start)
        XCTAssertEqual(DeepLinkHandler.parse(url: URL(string: "coronasdr://stop")!), .stop)
    }

    func testParseRejectsInvalidScheme() {
        let url = URL(string: "http://tune?freq=100000000&mode=WFM")!
        XCTAssertNil(DeepLinkHandler.parse(url: url))
    }

    @MainActor
    func testCoordinatorConsumesPendingAction() {
        let coordinator = DeepLinkCoordinator()
        coordinator.handle(url: URL(string: "coronasdr://start")!)

        XCTAssertEqual(coordinator.pendingAction, .start)
        XCTAssertEqual(coordinator.consumePendingAction(), .start)
        XCTAssertNil(coordinator.pendingAction)
    }
}
