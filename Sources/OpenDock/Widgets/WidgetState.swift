import Foundation

/// All mutable widget state travels with the DockItem so layout export includes it.
enum WidgetState {
    static func number(_ config: [String: String], _ key: String, default fallback: Double = 0) -> Double {
        guard let value = Double(config[key] ?? ""), value.isFinite else { return fallback }
        return value
    }

    static func boundedNumber(_ config: [String: String], _ key: String, default fallback: Double, range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, number(config, key, default: fallback)))
    }

    static func elapsed(_ config: [String: String], at date: Date) -> TimeInterval {
        let accumulated = boundedNumber(config, "elapsed", default: 0, range: 0...3_153_600_000)
        let started = number(config, "started")
        return min(3_153_600_000, accumulated + (started > 0 ? max(0, date.timeIntervalSince1970 - started) : 0))
    }

    static func remaining(_ config: [String: String], at date: Date, defaultDuration: Double) -> TimeInterval {
        let deadline = number(config, "deadline")
        if deadline > 0 { return min(86400, max(0, deadline - date.timeIntervalSince1970)) }
        return boundedNumber(config, "remaining", default: defaultDuration, range: 0...86400)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let safe = min(max(0, seconds), Double(Int.max / 2))
        let total = Int(safe)
        let hours = total / 3600
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func progress(_ component: Calendar.Component, at date: Date, calendar: Calendar = .current) -> Double {
        guard let interval = calendar.dateInterval(of: component, for: date), interval.duration > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(interval.start) / interval.duration))
    }

    static func hydration(_ config: [String: String]) -> [WaterEntry] {
        guard let data = config["waterHistory"]?.data(using: .utf8), let entries = try? JSONDecoder().decode([WaterEntry].self, from: data) else { return [] }
        return Array(entries.suffix(2000)).filter { ($0.milliliters == nil || (1...5000).contains($0.milliliters!)) && $0.timestamp.isFinite && (0...4_102_444_800).contains($0.timestamp) }
    }

    static func hydrationTotal(_ entries: [WaterEntry], at date: Date, calendar: Calendar = .current) -> Int {
        entries.filter { calendar.isDate(Date(timeIntervalSince1970: $0.timestamp), inSameDayAs: date) }.reduce(0) { $0 + ($1.milliliters ?? 0) }
    }

    static func encodedWater(_ entries: [WaterEntry]) -> String {
        guard let data = try? JSONEncoder().encode(Array(entries.suffix(2000))) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func alarmComponents(date: Date, weekdays: Set<Int>, calendar: Calendar = .current) -> [DateComponents] {
        if weekdays.isEmpty { return [calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)] }
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return weekdays.filter { (1...7).contains($0) }.sorted().map {
            var components = time; components.weekday = $0; return components
        }
    }

    static func hydrationReminderComponents(everyMinutes: Int, startHour: Int, endHour: Int) -> [DateComponents] {
        let interval = min(240, max(30, everyMinutes))
        let start = min(23, max(0, startHour)), end = min(24, max(start + 1, endHour))
        return stride(from: start * 60, to: end * 60, by: interval).prefix(48).map { DateComponents(hour: $0 / 60, minute: $0 % 60) }
    }

    static func strings(_ config: [String: String], _ key: String) -> [String] {
        guard let data = config[key]?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encodeStrings(_ strings: [String]) -> String {
        guard let data = try? JSONEncoder().encode(strings) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

struct WaterEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var timestamp: TimeInterval
    var milliliters: Int?
    var drink: String = "水"
    init(id: UUID = UUID(), timestamp: TimeInterval, milliliters: Int? = nil, drink: String = "水") {
        self.id = id; self.timestamp = timestamp; self.milliliters = milliliters; self.drink = drink
    }
    private enum CodingKeys: String, CodingKey { case id, timestamp, milliliters, drink }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        timestamp = try values.decode(Double.self, forKey: .timestamp)
        milliliters = try values.decodeIfPresent(Int.self, forKey: .milliliters)
        drink = try values.decodeIfPresent(String.self, forKey: .drink) ?? "水"
    }
}
