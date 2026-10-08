import Foundation

enum BusinessAdapters {
    static func load(account: IntegrationAccount, credentials: [String: String], period: IntegrationPeriod) async throws -> BusinessReport {
        var report: BusinessReport
        switch account.kind {
        case "stripe": report = try await stripe(key: credentials["key"] ?? "", period: period)
        case "paddle": report = try await paddle(key: credentials["key"] ?? "", sandbox: account.sandbox, period: period)
        case "shopify": report = try await shopify(domain: account.domain, credentials: credentials, period: period)
        default: throw IntegrationError.schema
        }
        if account.kind == "stripe" {
            let key = "business-history-" + account.id.uuidString
            let old = IntegrationDisk.read(BusinessReport.self, key: key)
            let day = Calendar.current.startOfDay(for: report.fetchedAt)
            for index in report.currencies.indices {
                for metric in ["mrr", "arr", "paying", "arpu"] {
                    guard let value = report.currencies[index].values[metric] else { continue }
                    var points = old?.currencies.first { $0.currency == report.currencies[index].currency }?.series[metric] ?? []
                    points.removeAll { $0.date == day }; points.append(IntegrationPoint(date: day, value: IntegrationNumber.double(value)))
                    report.currencies[index].series[metric] = points.sorted { $0.date < $1.date }.suffix(4000).map { $0 }
                }
            }
            try IntegrationDisk.write(report, key: key)
            let interval = period.interval()
            for index in report.currencies.indices {
                for metric in ["mrr", "arr", "paying", "arpu"] { report.currencies[index].series[metric] = report.currencies[index].series[metric]?.filter { interval.contains($0.date) } }
            }
        }
        return report
    }

    static func stripe(key: String, period: IntegrationPeriod) async throws -> BusinessReport {
        guard key.hasPrefix("rk_live_") || key.hasPrefix("rk_test_") else { throw IntegrationError.invalid("Stripe 需要 rk_live_ 或 rk_test_ 受限只读密钥。") }
        let interval = period.interval()
        let records = try await stripePages(path: "balance_transactions", key: key,
                                           query: [URLQueryItem(name: "created[gte]", value: String(Int(interval.start.timeIntervalSince1970))), URLQueryItem(name: "created[lt]", value: String(Int(interval.end.timeIntervalSince1970)))])
        do {
            let subscriptions = try await stripePages(path: "subscriptions", key: key, query: [URLQueryItem(name: "status", value: "all"), URLQueryItem(name: "expand[]", value: "data.items.data.price")])
            return try stripeReport(transactions: records, subscriptions: subscriptions, period: period, now: .now)
        } catch is CancellationError { throw CancellationError() } catch {
            var report = try stripeReport(transactions: records, subscriptions: [], period: period, now: .now)
            report.note += " 订阅读取未完成，MRR / ARR / 付费客户数不可用；保留已完整读取的收入与净额。"
            return report
        }
    }

    private static func stripePages(path: String, key: String, query: [URLQueryItem]) async throws -> [[String: Any]] {
        var records: [[String: Any]] = [], cursor: String?
        for _ in 0..<100 {
            var parameters = query + [URLQueryItem(name: "limit", value: "100")]
            if let cursor { parameters.append(URLQueryItem(name: "starting_after", value: cursor)) }
            let object = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://api.stripe.com/v1/\(path)", query: parameters), headers: ["Authorization": "Bearer " + key, "Stripe-Version": "2025-02-24.acacia"])
            guard let data = object["data"] as? [[String: Any]], let more = object["has_more"] as? Bool else { throw IntegrationError.schema }
            records.append(contentsOf: data)
            if !more { return records }
            guard let next = data.last?["id"] as? String, next != cursor, !data.isEmpty else { throw IntegrationError.schema }
            cursor = next
        }
        throw IntegrationError.incomplete
    }

    /// Financial arithmetic uses Decimal and never mixes currency buckets.
    static func stripeReport(transactions: [[String: Any]], subscriptions: [[String: Any]], period: IntegrationPeriod, now: Date) throws -> BusinessReport {
        var groups: [String: BusinessCurrency] = [:]
        var customers: [String: Set<String>] = [:]
        var metered = 0
        let accepted: Set<String> = ["charge", "refund", "refund_failure", "charge_failure", "partial_capture_reversal"]
        for row in transactions {
            let category = row["reporting_category"] as? String ?? ""
            guard accepted.contains(category) else { continue }
            guard let currency = row["currency"] as? String, let amount = IntegrationNumber.decimal(row["amount"]),
                  let net = IntegrationNumber.decimal(row["net"]), let date = IntegrationNumber.date(row["created"]) else { throw IntegrationError.schema }
            let code = currency.uppercased()
            var bucket = groups[code] ?? BusinessCurrency(currency: code, values: ["revenue": 0, "net": 0])
            let major = IntegrationNumber.major(amount, currency: code), afterFees = IntegrationNumber.major(net, currency: code)
            bucket.values["revenue", default: 0] += major; bucket.values["net", default: 0] += afterFees
            bucket.series["revenue", default: []].append(IntegrationPoint(date: date, value: IntegrationNumber.double(major)))
            bucket.series["net", default: []].append(IntegrationPoint(date: date, value: IntegrationNumber.double(afterFees)))
            groups[code] = bucket
        }
        var mrrUnavailable = false
        do { for subscription in subscriptions {
            guard ["active", "past_due"].contains(subscription["status"] as? String ?? "") else { continue }
            if let discounts = subscription["discounts"] as? [Any], !discounts.isEmpty { throw IntegrationError.schema }
            if subscription["discount"] is [String: Any] { throw IntegrationError.invalid("此账户包含复杂订阅折扣，无法可靠计算 MRR。") }
            guard let items = subscription["items"] as? [String: Any], let rows = items["data"] as? [[String: Any]], items["has_more"] as? Bool != true else { throw IntegrationError.incomplete }
            for item in rows {
                guard let price = item["price"] as? [String: Any], let recurring = price["recurring"] as? [String: Any] else { continue }
                if recurring["usage_type"] as? String == "metered" { metered += 1; continue }
                guard price["billing_scheme"] as? String == "per_unit", price["transform_quantity"] is NSNull || price["transform_quantity"] == nil,
                      let minor = IntegrationNumber.decimal(price["unit_amount_decimal"] ?? price["unit_amount"]), let currency = price["currency"] as? String,
                      let cadence = recurring["interval"] as? String else { throw IntegrationError.invalid("订阅含分层、转换数量或自定义价格；无法生成可靠的 MRR 估算。") }
                let count = max(1, IntegrationNumber.count(recurring["interval_count"]))
                let quantity = max(0, IntegrationNumber.count(item["quantity"]))
                let amount = IntegrationNumber.major(minor, currency: currency) * Decimal(quantity)
                let mrr: Decimal
                // Divide the total, not a precomputed repeating decimal reciprocal.
                switch cadence { case "month": mrr = amount / Decimal(count); case "year": mrr = amount / (12 * Decimal(count)); case "week": mrr = amount * Decimal(string: "52.1785714286")! / (12 * Decimal(count)); case "day": mrr = amount * Decimal(string: "365.25")! / (12 * Decimal(count)); default: throw IntegrationError.schema }
                let code = currency.uppercased()
                var bucket = groups[code] ?? BusinessCurrency(currency: code, values: ["revenue": 0, "net": 0])
                bucket.values["mrr", default: 0] += mrr
                if mrr > 0 {
                    let customer = (subscription["customer"] as? String) ?? (subscription["customer"] as? [String: Any])?["id"] as? String
                    guard let customer else { throw IntegrationError.schema }
                    customers[code, default: []].insert(customer)
                }
                groups[code] = bucket
            }
        } } catch { mrrUnavailable = true }
        for code in groups.keys {
            var bucket = groups[code]!
            if mrrUnavailable { bucket.values.removeValue(forKey: "mrr") }
            if let mrr = bucket.values["mrr"] {
                let count = customers[code]?.count ?? 0
                bucket.values["arr"] = mrr * 12; bucket.values["paying"] = Decimal(count)
                if count > 0 { bucket.values["arpu"] = mrr / Decimal(count) }
            }
            bucket.series = bucket.series.mapValues { daily($0, timeZone: .current) }
            groups[code] = bucket
        }
        let limitation = mrrUnavailable ? " 订阅包含未支持的折扣、分层或不完整项目，MRR / ARR / 付费客户数不可用；完整收入与净额仍可读取。" : ""
        return BusinessReport(currencies: groups.values.sorted { $0.currency < $1.currency }, fetchedAt: now, source: "Stripe Balance + Subscriptions", note: "收入含税、减退款与冲正、费用前；净额扣交易费。MRR 为 active / past_due 固定订阅估算，不含试用与 \(metered) 个按量项目。币种分别计算，按本机时区。订阅历史从连接后积累。" + limitation, period: period.rawValue)
    }

    static func paddle(key: String, sandbox: Bool, period: IntegrationPeriod) async throws -> BusinessReport {
        guard key.hasPrefix(sandbox ? "pdl_sdbx_apikey_" : "pdl_live_apikey_") else { throw IntegrationError.invalid("请使用与 Live / Sandbox 环境匹配的 Paddle Billing API key。") }
        let utc = TimeZone(secondsFromGMT: 0)!
        let interval = period.interval(timeZone: utc)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: interval.end))!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = utc; formatter.dateFormat = "yyyy-MM-dd"
        let query = [URLQueryItem(name: "from", value: formatter.string(from: interval.start)), URLQueryItem(name: "to", value: formatter.string(from: end))]
        let base = sandbox ? "https://sandbox-api.paddle.com" : "https://api.paddle.com"
        let headers = ["Authorization": "Bearer " + key, "Paddle-Version": "1"]
        let revenue = try await IntegrationHTTP.shared.json(IntegrationHTTP.url(base + "/metrics/revenue", query: query), headers: headers)
        let mrr = try await IntegrationHTTP.shared.json(IntegrationHTTP.url(base + "/metrics/monthly-recurring-revenue", query: query), headers: headers)
        let active = try await IntegrationHTTP.shared.json(IntegrationHTTP.url(base + "/metrics/active-subscribers", query: query), headers: headers)
        return try paddleReport(revenue: revenue, mrr: mrr, active: active, period: period)
    }
    static func paddleReport(revenue: [String: Any], mrr: [String: Any], active: [String: Any], period: IntegrationPeriod) throws -> BusinessReport {
        guard let data = revenue["data"] as? [String: Any], let code = data["currency_code"] as? String, let rows = data["timeseries"] as? [[String: Any]],
              let mrrData = mrr["data"] as? [String: Any], mrrData["currency_code"] as? String == code,
              let mrrRows = mrrData["timeseries"] as? [[String: Any]] else { throw IntegrationError.schema }
        func points(_ rows: [[String: Any]]) throws -> [IntegrationPoint] {
            try rows.map { row in
                guard let date = IntegrationNumber.date(row["timestamp"]), let amount = IntegrationNumber.decimal(row["amount"]) else { throw IntegrationError.schema }
                return IntegrationPoint(date: date, value: IntegrationNumber.double(IntegrationNumber.major(amount, currency: code)))
            }.sorted { $0.date < $1.date }
        }
        var bucket = BusinessCurrency(currency: code.uppercased(), values: ["net": 0, "orders": 0])
        for row in rows {
            guard let amount = IntegrationNumber.decimal(row["amount"]) else { throw IntegrationError.schema }
            bucket.values["net", default: 0] += IntegrationNumber.major(amount, currency: code)
            bucket.values["orders", default: 0] += Decimal(IntegrationNumber.count(row["count"]))
        }
        bucket.series["net"] = try points(rows); bucket.series["mrr"] = try points(mrrRows)
        bucket.series["arr"] = bucket.series["mrr"]?.map { IntegrationPoint(date: $0.date, value: $0.value * 12) }
        if let latest = mrrRows.sorted(by: { ($0["timestamp"] as? String ?? "") < ($1["timestamp"] as? String ?? "") }).last,
           let amount = IntegrationNumber.decimal(latest["amount"]) {
            let value = IntegrationNumber.major(amount, currency: code); bucket.values["mrr"] = value; bucket.values["arr"] = value * 12
        }
        if let series = (active["data"] as? [String: Any])?["timeseries"] as? [[String: Any]], let last = series.sorted(by: { ($0["timestamp"] as? String ?? "") < ($1["timestamp"] as? String ?? "") }).last,
           let count = IntegrationNumber.decimal(last["count"]) { bucket.values["paying"] = count }
        return BusinessReport(currencies: [bucket], fetchedAt: IntegrationNumber.date(data["updated_at"]) ?? .now, source: "Paddle Billing Metrics", note: "Paddle 报告的净营收：税费后、退款及拒付前。主余额币种、UTC 日期。MRR 为最新服务报告，ARR = MRR × 12，期间仅控制图表。", period: period.rawValue)
    }

    static func shopify(domain: String, credentials: [String: String], period: IntegrationPeriod) async throws -> BusinessReport {
        guard IntegrationHTTP.validShop(domain), let clientID = credentials["clientID"], let secret = credentials["secret"], !clientID.isEmpty, !secret.isEmpty else { throw IntegrationError.invalid("请填写属于同一组织的 myshopify.com 店铺、Client ID 与 Client secret。") }
        let authorization = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://\(domain)/admin/oauth/access_token"), form: ["grant_type": "client_credentials", "client_id": clientID, "client_secret": secret])
        guard let token = authorization["access_token"] as? String else { throw IntegrationError.invalid("Shopify 未返回访问令牌，请确认应用已发布并安装到同组织店铺。") }
        let endpoint = try IntegrationHTTP.url("https://\(domain)/admin/api/2026-07/graphql.json")
        let headers = ["X-Shopify-Access-Token": token]
        let shopResponse = try await IntegrationHTTP.shared.json(endpoint, headers: headers, body: ["query": "{ shop { ianaTimezone currencyCode } }"])
        guard shopResponse["errors"] == nil, let shop = (shopResponse["data"] as? [String: Any])?["shop"] as? [String: Any], let zoneName = shop["ianaTimezone"] as? String, let zone = TimeZone(identifier: zoneName) else { throw IntegrationError.invalid("无法读取店铺时区；请检查 read_orders 和应用安装。") }
        let interval = period.interval(timeZone: zone)
        let formatter = ISO8601DateFormatter()
        let search = "created_at:>=\(formatter.string(from: interval.start)) created_at:<\(formatter.string(from: interval.end))"
        var cursor: String?, orders: [[String: Any]] = []
        for _ in 0..<40 {
            var variables: [String: Any] = ["search": search]; if let cursor { variables["cursor"] = cursor }
            let query = "query Orders($search:String!,$cursor:String) { orders(first:250,after:$cursor,query:$search,sortKey:CREATED_AT) { pageInfo { hasNextPage endCursor } nodes { id createdAt test cancelledAt sourceName currentTotalPriceSet { shopMoney { amount currencyCode } } lineItems(first:250) { pageInfo { hasNextPage endCursor } nodes { title currentQuantity } } } } }"
            let object = try await IntegrationHTTP.shared.json(endpoint, headers: headers, body: ["query": query, "variables": variables])
            guard object["errors"] == nil, let data = (object["data"] as? [String: Any])?["orders"] as? [String: Any], let rows = data["nodes"] as? [[String: Any]], let page = data["pageInfo"] as? [String: Any] else { throw IntegrationError.invalid("Shopify 订单查询失败。请检查 read_orders；旧订单可能还需 read_all_orders。") }
            for var order in rows {
                if var items = order["lineItems"] as? [String: Any], var more = items["pageInfo"] as? [String: Any], more["hasNextPage"] as? Bool == true {
                    var all = items["nodes"] as? [[String: Any]] ?? []
                    guard let identifier = order["id"] as? String else { throw IntegrationError.schema }
                    for _ in 0..<40 {
                        guard let next = more["endCursor"] as? String else { throw IntegrationError.schema }
                        let lineQuery = "query Lines($id:ID!,$cursor:String!) { order(id:$id) { lineItems(first:250,after:$cursor) { pageInfo { hasNextPage endCursor } nodes { title currentQuantity } } } }"
                        let response = try await IntegrationHTTP.shared.json(endpoint, headers: headers, body: ["query": lineQuery, "variables": ["id": identifier, "cursor": next]])
                        guard response["errors"] == nil, let result = (response["data"] as? [String: Any])?["order"] as? [String: Any], let lines = result["lineItems"] as? [String: Any], let nodes = lines["nodes"] as? [[String: Any]], let nextPage = lines["pageInfo"] as? [String: Any] else { throw IntegrationError.schema }
                        all.append(contentsOf: nodes); more = nextPage
                        if more["hasNextPage"] as? Bool != true { break }
                    }
                    guard more["hasNextPage"] as? Bool != true else { throw IntegrationError.incomplete }
                    items["nodes"] = all; order["lineItems"] = items
                }
                orders.append(order)
            }
            if page["hasNextPage"] as? Bool != true { return try shopifyReport(orders: orders, timeZone: zone, period: period) }
            guard let next = page["endCursor"] as? String, next != cursor else { throw IntegrationError.schema }; cursor = next
        }
        throw IntegrationError.incomplete
    }
    static func shopifyReport(orders: [[String: Any]], timeZone: TimeZone, period: IntegrationPeriod) throws -> BusinessReport {
        guard orders.count <= 10_000 else { throw IntegrationError.incomplete }
        var buckets: [String: BusinessCurrency] = [:]
        for row in orders {
            guard row["test"] as? Bool != true, row["cancelledAt"] == nil || row["cancelledAt"] is NSNull else { continue }
            guard let money = (row["currentTotalPriceSet"] as? [String: Any])?["shopMoney"] as? [String: Any], let code = money["currencyCode"] as? String,
                  let amount = IntegrationNumber.decimal(money["amount"]), let date = IntegrationNumber.date(row["createdAt"]) else { throw IntegrationError.schema }
            var bucket = buckets[code] ?? BusinessCurrency(currency: code, values: ["revenue": 0, "orders": 0])
            bucket.values["revenue", default: 0] += amount; bucket.values["orders", default: 0] += 1
            bucket.series["revenue", default: []].append(IntegrationPoint(date: date, value: IntegrationNumber.double(amount)))
            bucket.series["orders", default: []].append(IntegrationPoint(date: date, value: 1))
            bucket.channels[row["sourceName"] as? String ?? "未知", default: 0] += 1
            for line in (row["lineItems"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] {
                bucket.products[line["title"] as? String ?? "未命名商品", default: 0] += Double(IntegrationNumber.count(line["currentQuantity"]))
            }
            buckets[code] = bucket
        }
        for code in buckets.keys {
            var bucket = buckets[code]!
            if let count = bucket.values["orders"], count > 0 { bucket.values["aov"] = bucket.values["revenue", default: 0] / count }
            bucket.series = bucket.series.mapValues { daily($0, timeZone: timeZone) }
            buckets[code] = bucket
        }
        return BusinessReport(currencies: buckets.values.sorted { $0.currency < $1.currency }, fetchedAt: .now, source: "Shopify GraphQL Admin 2026-07", note: "订单当前金额：折扣／退货后，含税和运费，含未付款与全额退货订单，排除测试／取消订单。按店铺时区 \(timeZone.identifier)。商品显示剩余数量；来源显示订单来源，订单 API 不提供真实访客流量。", period: period.rawValue)
    }
    static func daily(_ points: [IntegrationPoint], timeZone: TimeZone) -> [IntegrationPoint] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var totals: [Date: Double] = [:]
        for point in points { totals[calendar.startOfDay(for: point.date), default: 0] += point.value }
        return totals.map { IntegrationPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }
}
