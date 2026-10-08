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

    func testPausedTimelineHasOneEntryAndCountdownStopsAtDeadline() {
        let start = Date(timeIntervalSince1970: 2000)
        XCTAssertEqual(Array(WidgetTimeline(kind: .stopwatch, configuration: ["elapsed": "20"]).entries(from: start, mode: .normal)), [start])
        let countdown = Array(WidgetTimeline(kind: .countdown, configuration: ["deadline": "2002.5"]).entries(from: start, mode: .normal))
        XCTAssertEqual(countdown.map(\.timeIntervalSince1970), [2000, 2001, 2002, 2002.5])
        XCTAssertEqual(Array(WidgetTimeline(kind: .focus, configuration: ["deadline": "1900"]).entries(from: start, mode: .normal)), [start])
    }

    func testAlarmAndHydrationNotificationComponents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9, minute: 30))!
        let weekly = WidgetState.alarmComponents(date: date, weekdays: [2, 6], calendar: calendar)
        XCTAssertEqual(weekly.map(\.weekday), [2, 6])
        XCTAssertTrue(weekly.allSatisfy { $0.hour == 9 && $0.minute == 30 && $0.year == nil })
        let once = WidgetState.alarmComponents(date: date, weekdays: [], calendar: calendar)
        XCTAssertEqual(once.first?.year, 2026)
        let water = WidgetState.hydrationReminderComponents(everyMinutes: 60, startHour: 8, endHour: 22)
        XCTAssertEqual(water.count, 14)
        XCTAssertTrue(water.allSatisfy { (8..<22).contains($0.hour ?? -1) && $0.minute == 0 })
    }

    func testHydrationAllowsUnspecifiedAmountsAndDecodesOriginalHistory() throws {
        let entry = WaterEntry(timestamp: 1_700_000_000, milliliters: nil, drink: "茶")
        let config = ["waterHistory": WidgetState.encodedWater([entry])]
        XCTAssertEqual(WidgetState.hydration(config), [entry])
        XCTAssertEqual(WidgetState.hydrationTotal([entry], at: Date(timeIntervalSince1970: entry.timestamp)), 0)
        let legacy = "[{\"id\":\"\(entry.id.uuidString)\",\"timestamp\":1700000000,\"milliliters\":250}]"
        XCTAssertEqual(WidgetState.hydration(["waterHistory": legacy]).first?.drink, "水")
    }

    func testMeetingLinkUsesKnownHostsAndIgnoresLookalikes() {
        XCTAssertEqual(MeetingLink.parse(url: nil, location: "会议 https://meet.google.com/abc-defg-hij", notes: nil)?.host, "meet.google.com")
        XCTAssertEqual(MeetingLink.parse(url: nil, location: nil, notes: "Join https://company.zoom.us/j/123?pwd=test")?.host, "company.zoom.us")
        XCTAssertNil(MeetingLink.parse(url: URL(string: "https://zoom.us.evil.example/j/123"), location: nil, notes: nil))
        XCTAssertEqual(MeetingLink.parse(url: URL(string: "zoommtg://zoom.us/join?confno=123"), location: nil, notes: nil)?.scheme, "zoommtg")
    }
}
