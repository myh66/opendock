import Foundation

/// Both endpoints are real observations, never interpolated or chart-sampled values.
struct StockChartSelection: Equatable {
    let start: IntegrationPoint
    let end: IntegrationPoint

    init(start: IntegrationPoint, end: IntegrationPoint) {
        if start.date <= end.date { self.start = start; self.end = end }
        else { self.start = end; self.end = start }
    }

    var change: Double? {
        let value = end.value - start.value
        return value.isFinite ? value : nil
    }

    var percentChange: Double? {
        guard start.value > 0, let change else { return nil }
        let value = (change / start.value) * 100
        return value.isFinite ? value : nil
    }

    var duration: TimeInterval { end.date.timeIntervalSince(start.date) }

    static func orderedPoints(_ points: [IntegrationPoint]) -> [IntegrationPoint] {
        points.filter { $0.value.isFinite && $0.date.timeIntervalSince1970.isFinite && abs($0.date.timeIntervalSince1970) <= 9_000_000_000 }
            .sorted { $0.date == $1.date ? $0.value < $1.value : $0.date < $1.date }
    }

    /// Works with unsorted input and resolves equal-distance ties toward the earlier date.
    static func nearestPoint(to date: Date, in points: [IntegrationPoint]) -> IntegrationPoint? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        var closest: IntegrationPoint?, distance = TimeInterval.infinity
        for point in points {
            guard point.value.isFinite, point.date.timeIntervalSince1970.isFinite, abs(point.date.timeIntervalSince1970) <= 9_000_000_000 else { continue }
            let candidate = abs(point.date.timeIntervalSince(date))
            if candidate < distance || (candidate == distance && (closest == nil || point.date < closest!.date)) {
                closest = point; distance = candidate
            }
        }
        return closest
    }

    static func comparing(_ points: [IntegrationPoint], from start: Date, to end: Date) -> StockChartSelection? {
        guard let first = nearestPoint(to: start, in: points), let last = nearestPoint(to: end, in: points) else { return nil }
        return StockChartSelection(start: first, end: last)
    }
}
