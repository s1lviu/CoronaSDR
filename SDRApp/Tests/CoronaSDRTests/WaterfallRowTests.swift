import XCTest
@testable import SDRRender

final class WaterfallRowTests: XCTestCase {
    func testDownsamplingPreservesSignalsInBothHalves() {
        XCTAssertEqual(row([0, 1, 0, 0, 0, 0, 0, 1], width: 4), [1, 0, 0, 1])
    }

    func testFractionalReductionIncludesTheRightEdge() {
        XCTAssertEqual(row([0, 1, 2, 3, 4, 5, 6], width: 4), [0, 2, 4, 6])
    }

    func testMediumAndHighKeepLeftCenterAndRightSignals() {
        var bins = [Float](repeating: 0, count: 4096)
        bins[0] = 0.25
        bins[2048] = 0.5
        bins[4095] = 1
        let result = row(bins, width: 2048)
        XCTAssertEqual(result[0], 0.25)
        XCTAssertEqual(result[1024], 0.5)
        XCTAssertEqual(result[2047], 1)
        XCTAssertEqual(result.filter { $0 > 0 }.count, 3)
    }

    func testFractionalZoomKeepsTheLastVisibleSignal() {
        var bins = [Float](repeating: 0, count: 2730)
        bins[2729] = 1
        XCTAssertEqual(row(bins, width: 2048).last, 1)
    }

    func testEqualWidthKeepsEveryBin() {
        XCTAssertEqual(row([0, 0.75, 0.25, 1], width: 4), [0, 0.75, 0.25, 1])
    }

    func testUpsamplingInterpolatesTheFullSpan() {
        XCTAssertEqual(row([0, 1], width: 5), [0, 0.25, 0.5, 0.75, 1])
    }

    func testSingleBinFillsTheRow() {
        XCTAssertEqual(row([0.5], width: 4), [0.5, 0.5, 0.5, 0.5])
    }

    private func row(_ bins: [Float], width: Int) -> [Float] {
        var output = [Float](repeating: 0, count: width)
        resampleWaterfallRow(bins, into: &output)
        return output
    }
}
