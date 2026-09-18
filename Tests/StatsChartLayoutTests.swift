import XCTest
@testable import DuoTranslator

/// The floor exists so a rare failure is visible; it must not buy that by
/// making the chart lie about how many requests a day had.
final class StatsChartLayoutTests: XCTestCase {
    private func plotted(_ segments: [(String, Int)], axisMax: Int) -> [StatsChartLayout.Segment] {
        StatsChartLayout.plotted(
            segments: segments.map { (status: $0.0, count: $0.1) },
            axisMax: axisMax,
            successLabel: "成功"
        )
    }

    func testARareFailureIsRaisedToTheFloor() {
        let bars = plotted([("成功", 799), ("失败", 1)], axisMax: 900)
        let failure = bars.first { $0.status == "失败" }!
        XCTAssertEqual(failure.plotted, 22.5, accuracy: 0.001) // 2.5% of 900
        XCTAssertEqual(failure.count, 1) // the real number is untouched
    }

    func testTheBarStillTotalsTheDaysRequests() {
        let bars = plotted([("成功", 799), ("失败", 1)], axisMax: 900)
        // The floor moves the boundary inside the bar; it never inflates it.
        XCTAssertEqual(bars.map(\.plotted).reduce(0, +), 800, accuracy: 0.001)
    }

    func testASegmentAlreadyTallerThanTheFloorIsLeftAlone() {
        let bars = plotted([("成功", 500), ("失败", 300)], axisMax: 900)
        XCTAssertEqual(bars.first { $0.status == "失败" }!.plotted, 300, accuracy: 0.001)
        XCTAssertEqual(bars.first { $0.status == "成功" }!.plotted, 500, accuracy: 0.001)
    }

    func testADayWithoutFailuresIsUnchanged() {
        let bars = plotted([("成功", 812)], axisMax: 900)
        XCTAssertEqual(bars.map(\.plotted), [812])
    }

    func testSeveralRaisedSegmentsAllBorrowFromSuccess() {
        let bars = plotted([("成功", 798), ("失败", 1), ("取消", 1)], axisMax: 900)
        XCTAssertEqual(bars.map(\.plotted).reduce(0, +), 800, accuracy: 0.001)
        for status in ["失败", "取消"] {
            XCTAssertEqual(bars.first { $0.status == status }!.plotted, 22.5, accuracy: 0.001)
        }
    }

    func testADayOfNothingButFailuresKeepsItsSegment() {
        // Nothing to borrow from: the segment stays visible and success cannot
        // go negative, at the cost of a bar a hair taller than its count.
        let bars = plotted([("成功", 0), ("失败", 2)], axisMax: 900)
        XCTAssertEqual(bars.first { $0.status == "成功" }!.plotted, 0)
        XCTAssertEqual(bars.first { $0.status == "失败" }!.plotted, 22.5, accuracy: 0.001)
    }

    func testAnEmptyChartDoesNotDivideByZero() {
        let bars = plotted([("成功", 0)], axisMax: 0)
        XCTAssertEqual(bars.map(\.plotted), [0])
    }
}
