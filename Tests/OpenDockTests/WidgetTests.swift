import XCTest
@testable import OpenDock

final class WidgetTests: XCTestCase {
    func testRunningStopwatchRestoresFromStartDateAndPause() {
        let date = Date(timeIntervalSince1970: 2000)
        XCTAssertEqual(WidgetState.elapsed(["elapsed": "20", "started": "1900"], at: date), 120)
        XCTAssertEqual(WidgetState.elapsed(["elapsed": "120", "started": ""], at: date.addingTimeInterval(100)), 120)
    }

    func testCountdownContinuesAcrossClosingAndClampsAtZero() {
        let config = ["deadline": "2060", "duration": "60"]
        XCTAssertEqual(WidgetState.remaining(config, at: Date(timeIntervalSince1970: 2000), defaultDuration: 60), 60)
        XCTAssertEqual(WidgetState.remaining(config, at: Date(timeIntervalSince1970: 2070), defaultDuration: 60), 0)
        XCTAssertEqual(WidgetState.remaining(["remaining": "23"], at: Date(timeIntervalSince1970: 9000), defaultDuration: 60), 23)
    }

    func testImportedNonfiniteAndHugeValuesFailSoft() {
        for invalid in ["nan", "inf", "-inf", "1e999", "hello"] {
            XCTAssertEqual(WidgetState.number(["n": invalid], "n", default: 25), 25)
        }
        XCTAssertEqual(Int(WidgetState.boundedNumber(["duration": "1e300"], "duration", default: 1500, range: 60...86400)), 86400)
        XCTAssertEqual(Int(WidgetState.boundedNumber(["waterGoal": "1e300"], "waterGoal", default: 2000, range: 1...10000)), 10000)
        XCTAssertEqual(WidgetState.remaining(["deadline": "1e300"], at: .now, defaultDuration: 60), 86400)
        XCTAssertEqual(WidgetState.elapsed(["elapsed": "1e300"], at: .now), 3_153_600_000)
        XCTAssertEqual(WidgetState.durationText(-10), "00:00")
    }

    func testHydrationUsesLocalDayAndRetainsHistoryForUndo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [WaterEntry(timestamp: today.timeIntervalSince1970, milliliters: 250), WaterEntry(timestamp: today.addingTimeInterval(-86400).timeIntervalSince1970, milliliters: 300)]
        XCTAssertEqual(WidgetState.hydrationTotal(entries, at: today, calendar: calendar), 250)
        let restored = WidgetState.hydration(["waterHistory": WidgetState.encodedWater(entries)])
        XCTAssertEqual(restored, entries)
        XCTAssertEqual(WidgetState.hydrationTotal(Array(restored.dropFirst()), at: today, calendar: calendar), 0)
        XCTAssertTrue(WidgetState.hydration(["waterHistory": "malformed"]).isEmpty)
        XCTAssertTrue(WidgetState.hydration(["waterHistory": WidgetState.encodedWater([WaterEntry(timestamp: 1e300, milliliters: 250)])]).isEmpty)
    }

    func testCalendarProgressRespectsActualInterval() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2024, month: 2, day: 15, hour: 12))!
        XCTAssertEqual(WidgetState.progress(.day, at: date, calendar: calendar), 0.5, accuracy: 0.000001)
        XCTAssertEqual(WidgetState.progress(.month, at: date, calendar: calendar), 0.5, accuracy: 0.000001)
    }
}
