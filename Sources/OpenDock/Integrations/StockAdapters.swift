import Foundation

enum StockAdapters {
    static let ranges = ["1d", "5d", "1mo", "3mo", "6mo", "ytd", "1y", "5y", "max"]
    static func validSymbol(_ symbol: String) -> Bool { symbol.range(of: #"^[A-Za-z0-9^=._-]{1,30}$"#, options: .regularExpression) != nil }
    static func yahoo(symbol: String, range: String) async throws -> StockReport {
        guard validSymbol(symbol), ranges.contains(range) else { throw IntegrationError.invalid("请输入有效交易代码与日期范围。") }
        let interval = range == "1d" ? "5m" : range == "5d" ? "30m" : ["5y", "max"].contains(range) ? "1wk" : "1d"
        let base = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart")!.appendingPathComponent(symbol)
        let object = try await IntegrationHTTP.shared.json(IntegrationHTTP.url(base.absoluteString, query: [URLQueryItem(name: "range", value: range), URLQueryItem(name: "interval", value: interval)]))
        return try yahooReport(object, symbol: symbol, range: range)
    }
    static func yahooReport(_ object: [String: Any], symbol: String, range: String) throws -> StockReport {
        guard let chart = object["chart"] as? [String: Any], chart["error"] == nil || chart["error"] is NSNull,
              let first = (chart["result"] as? [[String: Any]])?.first, let meta = first["meta"] as? [String: Any],
              let timestamps = first["timestamp"] as? [Any], let indicator = first["indicators"] as? [String: Any],
              let quote = (indicator["quote"] as? [[String: Any]])?.first, let closes = quote["close"] as? [Any] else { throw IntegrationError.noData }
        let volumes = quote["volume"] as? [Any] ?? []
        var points: [IntegrationPoint] = []
        for index in 0..<min(timestamps.count, closes.count) {
            guard let date = IntegrationNumber.date(timestamps[index]), let close = IntegrationNumber.quantity(closes[index]) else { continue }
            points.append(IntegrationPoint(date: date, value: close, volume: index < volumes.count ? IntegrationNumber.quantity(volumes[index]) : nil))
        }
        guard !points.isEmpty else { throw IntegrationError.noData }
        return StockReport(symbol: symbol.uppercased(), name: meta["longName"] as? String ?? meta["shortName"] as? String ?? symbol,
                           currency: meta["currency"] as? String ?? "", points: points.sorted { $0.date < $1.date }, fetchedAt: .now,
                           source: "Yahoo Finance", range: range, note: "Yahoo 公开网页数据端点无稳定 API 保证；行情可能延迟。失败时可改用 Alpha Vantage。")
    }
    static func search(_ query: String, provider: String, key: String?) async throws -> [(String, String)] {
        guard query.count >= 1, query.count <= 100 else { return [] }
        if provider == "alpha" {
            guard let key, !key.isEmpty else { throw IntegrationError.invalid("先连接 Alpha Vantage API key。") }
            let object = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://www.alphavantage.co/query", query: [URLQueryItem(name: "function", value: "SYMBOL_SEARCH"), URLQueryItem(name: "keywords", value: query), URLQueryItem(name: "apikey", value: key)]))
            guard let rows = object["bestMatches"] as? [[String: Any]] else { throw IntegrationError.invalid("Alpha Vantage 搜索暂不可用；请检查配额和 API key。") }
            return rows.compactMap { row in guard let code = row["1. symbol"] as? String, validSymbol(code) else { return nil }; return (code, row["2. name"] as? String ?? code) }
        }
        let object = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://query1.finance.yahoo.com/v1/finance/search", query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "quotesCount", value: "12"), URLQueryItem(name: "newsCount", value: "0")]))
        guard let rows = object["quotes"] as? [[String: Any]] else { throw IntegrationError.noData }
        return rows.compactMap { row in guard let code = row["symbol"] as? String, validSymbol(code) else { return nil }; return (code, row["shortname"] as? String ?? row["longname"] as? String ?? code) }
    }
    static func alpha(symbol: String, range: String, key: String) async throws -> StockReport {
        guard validSymbol(symbol), !key.isEmpty else { throw IntegrationError.invalid("请输入交易代码并连接 Alpha Vantage。") }
        let daily = !["1d", "5d"].contains(range)
        var query = [URLQueryItem(name: "function", value: daily ? "TIME_SERIES_DAILY" : "TIME_SERIES_INTRADAY"), URLQueryItem(name: "symbol", value: symbol), URLQueryItem(name: "outputsize", value: ["6mo", "1y", "5y", "max", "ytd"].contains(range) ? "full" : "compact"), URLQueryItem(name: "apikey", value: key)]
        if !daily { query.append(URLQueryItem(name: "interval", value: "5min")) }
        let object = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://www.alphavantage.co/query", query: query))
        guard object["Error Message"] == nil, object["Note"] == nil, object["Information"] == nil else { throw IntegrationError.invalid("Alpha Vantage 拒绝或限制了此请求。免费方案不提供完整历史／盘中数据；请更换范围、等待配额或使用对应计划。") }
        return try alphaReport(object, symbol: symbol, range: range)
    }
    static func alphaReport(_ object: [String: Any], symbol: String, range: String) throws -> StockReport {
        guard let key = object.keys.first(where: { $0.hasPrefix("Time Series") }), let series = object[key] as? [String: [String: Any]] else { throw IntegrationError.noData }
        let zone = ((object["Meta Data"] as? [String: Any])?["5. Time Zone"] as? String) ?? ((object["Meta Data"] as? [String: Any])?["6. Time Zone"] as? String) ?? "US/Eastern"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: zone)
        var points: [IntegrationPoint] = []
        for (stamp, row) in series {
            formatter.dateFormat = stamp.count > 10 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
            guard let date = formatter.date(from: stamp), let close = IntegrationNumber.quantity(row["4. close"]) else { continue }
            points.append(IntegrationPoint(date: date, value: close, volume: IntegrationNumber.quantity(row["5. volume"])))
        }
        points.sort { $0.date < $1.date }
        guard let end = points.last?.date else { throw IntegrationError.noData }
        let days: Double = ["1d": 1, "5d": 5, "1mo": 31, "3mo": 93, "6mo": 186, "1y": 366, "5y": 1830][range] ?? .infinity
        var start = days.isFinite ? end.addingTimeInterval(-days * 86400) : Date.distantPast
        if range == "ytd" { start = Calendar.current.dateInterval(of: .year, for: end)?.start ?? end }
        if days.isFinite || range == "ytd" { points = points.filter { $0.date >= start } }
        return StockReport(symbol: symbol, name: symbol, currency: "", points: points, fetchedAt: .now, source: "Alpha Vantage", range: range,
                           note: "按供应商实际返回的数据绘制；免费日线通常仅 100 个数据点，完整／盘中数据需要对应计划。交易币种以供应商或交易所为准。")
    }
}
