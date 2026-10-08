import XCTest
@testable import OpenDock

final class StockChartSelectionTests: XCTestCase {
    private func point(_ seconds: Double, _ value: Double) -> IntegrationPoint {
        IntegrationPoint(date: Date(timeIntervalSince1970: seconds), value: value, volume: nil)
    }

    func testForwardAndReverseDragsHaveTheSameChronologicalComparison() throws {
        let points = [point(300, 105), point(100, 100), point(200, 120)]
        let forward = try XCTUnwrap(StockChartSelection.comparing(points, from: Date(timeIntervalSince1970: 90), to: Date(timeIntervalSince1970: 290)))
        let reverse = try XCTUnwrap(StockChartSelection.comparing(points, from: Date(timeIntervalSince1970: 290), to: Date(timeIntervalSince1970: 90)))
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.start.date, points[1].date); XCTAssertEqual(forward.end.date, points[0].date)
        XCTAssertEqual(forward.change, 5); XCTAssertEqual(forward.percentChange, 5)
        XCTAssertEqual(forward.duration, 200)
    }

    func testNearestPointUsesOriginalObservationsAndClampsOutsideHistory() throws {
        let points = (0..<1001).map { point(Double($0), Double($0 + 1)) }
        XCTAssertEqual(StockChartSelection.nearestPoint(to: Date(timeIntervalSince1970: 499), in: points)?.value, 500)
        XCTAssertEqual(StockChartSelection.nearestPoint(to: Date(timeIntervalSince1970: -100), in: points), points.first)
        XCTAssertEqual(StockChartSelection.nearestPoint(to: Date(timeIntervalSince1970: 5000), in: points), points.last)
        XCTAssertEqual(StockChartSelection.nearestPoint(to: Date(timeIntervalSince1970: 499.5), in: points), points[499])
        let range = try XCTUnwrap(StockChartSelection.comparing(points, from: points[499].date, to: points[501].date))
        XCTAssertEqual(range.change, 2)
        XCTAssertEqual(try XCTUnwrap(range.percentChange), 0.4, accuracy: 0.00001)
    }

    func testDeclineZeroBaselineAndSingleObservationAreTruthful() {
        let decline = StockChartSelection(start: point(100, 100), end: point(200, 75))
        XCTAssertEqual(decline.change, -25); XCTAssertEqual(decline.percentChange, -25)
        let zero = StockChartSelection(start: point(100, 0), end: point(200, 5))
        XCTAssertEqual(zero.change, 5); XCTAssertNil(zero.percentChange)
        let same = StockChartSelection(start: point(100, 5), end: point(100, 5))
        XCTAssertEqual(same.change, 0); XCTAssertEqual(same.percentChange, 0); XCTAssertEqual(same.duration, 0)
    }

    func testMalformedAndExtremeValuesCannotProduceNonfiniteComparison() {
        let valid = point(100, 5)
        XCTAssertEqual(StockChartSelection.orderedPoints([point(.nan, 1), point(200, .infinity), point(1e300, 7), valid]), [valid])
        XCTAssertNil(StockChartSelection.nearestPoint(to: Date(timeIntervalSince1970: .nan), in: [valid]))
        XCTAssertNil(StockChartSelection.comparing([], from: valid.date, to: valid.date))
        let overflowing = StockChartSelection(start: point(100, -Double.greatestFiniteMagnitude), end: point(200, Double.greatestFiniteMagnitude))
        XCTAssertNil(overflowing.change); XCTAssertNil(overflowing.percentChange)
        let percentageOverflow = StockChartSelection(start: point(100, Double.leastNonzeroMagnitude), end: point(200, 1))
        XCTAssertEqual(percentageOverflow.change, 1); XCTAssertNil(percentageOverflow.percentChange)
    }
}
