import XCTest
@testable import OpenDock

final class IntegrationTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_790_928_000)
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func transaction(currency: String = "usd", amount: Int = 1000, net: Int = 950, category: String = "charge") -> [String: Any] {
        ["currency": currency, "amount": amount, "net": net, "reporting_category": category, "created": stamp.timeIntervalSince1970]
    }
    private func subscription(customer: String = "synthetic-customer", quantity: Int = 1, cadence: String = "month", amount: Int = 1200, status: String = "active", metered: Bool = false) -> [String: Any] {
        ["customer": customer, "status": status, "items": ["has_more": false, "data": [["quantity": quantity, "price": ["currency": "usd", "unit_amount": amount, "billing_scheme": "per_unit", "recurring": ["interval": cadence, "interval_count": 1, "usage_type": metered ? "metered" : "licensed"]]]]]]
    }
    func testCursorMissingNumericFieldsRetainUnavailableAndPartialMarkers() throws {
        let rows:[[String:Any]] = [["timestamp":1_800_000_000_000], ["timestamp":1_800_000_000_000,"tokenUsage":["inputTokens":12,"totalCents":1],"requestsCosts":1]]
        let records = try AIAdapters.cursorActivity(rows)
        XCTAssertEqual(records[0].tokenCoverage,"unavailable")
        XCTAssertEqual(records[1].tokenCoverage,"partial")
        XCTAssertNil(records[0].costUSD)
        XCTAssertEqual(records[0].requestsReported,false)
        XCTAssertEqual(records[1].tokens,12)
    }
    func testFiniteRejectsBooleansInfinityAndCountsOverflow() {
        XCTAssertNil(IntegrationNumber.finite(true)); XCTAssertNil(IntegrationNumber.finite("NaN")); XCTAssertNil(IntegrationNumber.finite(Double.infinity))
        XCTAssertEqual(IntegrationNumber.count(-1), 0); XCTAssertEqual(IntegrationNumber.count(1e30), 0)
        XCTAssertEqual(IntegrationNumber.major(1234, currency: "JPY"), 1234)
        XCTAssertEqual(IntegrationNumber.major(1234, currency: "KWD"), Decimal(string: "1.234"))
        XCTAssertEqual(IntegrationNumber.major(1234, currency: "USD"), Decimal(string: "12.34"))
    }
    func testL7IncludesTodayAndSixPreviousDates() {
        let zone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_791_417_600 + 3600)
        let period = IntegrationPeriod.l7.interval(at: now, timeZone: zone)
        XCTAssertEqual(period.end, now)
        XCTAssertEqual(period.end.timeIntervalSince(period.start), 6 * 86400 + 3600, accuracy: 1)
    }
    func testStripeSeparatesCurrenciesRefundsAndFees() throws {
        let report = try BusinessAdapters.stripeReport(transactions: [transaction(), transaction(amount: -200, net: -200, category: "refund"), transaction(currency: "jpy", amount: 1234, net: 1200), transaction(amount: 999999, net: 999999, category: "payout")], subscriptions: [], period: .today, now: stamp)
        let usd = try XCTUnwrap(report.currencies.first { $0.currency == "USD" })
        let jpy = try XCTUnwrap(report.currencies.first { $0.currency == "JPY" })
        XCTAssertEqual(usd.values["revenue"], 8); XCTAssertEqual(usd.values["net"], Decimal(string: "7.5"))
        XCTAssertEqual(jpy.values["revenue"], 1234)
    }
    func testStripeMonthlyNormalizationAndUniqueCustomers() throws {
        let report = try BusinessAdapters.stripeReport(transactions: [], subscriptions: [subscription(), subscription(cadence: "year", amount: 12000), subscription(customer: "second", quantity: 2, amount: 300), subscription(customer: "trial", status: "trialing"), subscription(customer: "metered", metered: true)], period: .l30, now: stamp)
        let usd = try XCTUnwrap(report.currencies.first)
        XCTAssertEqual(usd.values["mrr"], 28); XCTAssertEqual(usd.values["arr"], 336)
        XCTAssertEqual(usd.values["paying"], 2); XCTAssertEqual(usd.values["arpu"], 14)
    }
    func testUnsupportedStripeSubscriptionRetainsRevenueWithoutPartialMRR() throws {
        var discounted = subscription(); discounted["discounts"] = ["synthetic-discount"]
        let report = try BusinessAdapters.stripeReport(transactions: [transaction()], subscriptions: [subscription(), discounted], period: .today, now: stamp)
        XCTAssertEqual(report.currencies.first?.values["revenue"], 10)
        XCTAssertNil(report.currencies.first?.values["mrr"]); XCTAssertNil(report.currencies.first?.values["paying"])
        XCTAssertTrue(report.note.contains("不可用"))
    }
    func testPaddleMatchesDocumentedTimeseriesShapes() throws {
        let revenue: [String: Any] = ["data": ["currency_code": "USD", "updated_at": "2026-10-08T10:00:00Z", "timeseries": [["timestamp": "2026-10-07T00:00:00Z", "amount": "12000", "count": 4], ["timestamp": "2026-10-08T00:00:00Z", "amount": "5000", "count": 2]]]]
        let mrr: [String: Any] = ["data": ["currency_code": "USD", "timeseries": [["timestamp": "2026-10-08T00:00:00Z", "amount": "25000"]]]]
        let active: [String: Any] = ["data": ["timeseries": [["timestamp": "2026-10-08T00:00:00Z", "count": 12]]]]
        let report = try BusinessAdapters.paddleReport(revenue: revenue, mrr: mrr, active: active, period: .l7)
        XCTAssertEqual(report.currencies.first?.values["net"], 170)
        XCTAssertEqual(report.currencies.first?.values["orders"], 6)
        XCTAssertEqual(report.currencies.first?.values["mrr"], 250)
        XCTAssertEqual(report.currencies.first?.values["arr"], 3000)
        XCTAssertEqual(report.currencies.first?.values["paying"], 12)
    }
    func testShopifyIncludesUnpaidAndReturnedButExcludesTestCancelled() throws {
        func order(amount: String, test: Bool = false, cancelled: Any = NSNull()) -> [String: Any] {
            ["test": test, "cancelledAt": cancelled, "createdAt": "2026-10-08T02:00:00Z", "sourceName": "web", "currentTotalPriceSet": ["shopMoney": ["amount": amount, "currencyCode": "USD"]], "lineItems": ["nodes": [["title": "Synthetic product", "currentQuantity": 1]]]]
        }
        let report = try BusinessAdapters.shopifyReport(orders: [order(amount: "12.34"), order(amount: "0"), order(amount: "999", test: true), order(amount: "999", cancelled: "2026-10-08")], timeZone: TimeZone(secondsFromGMT: 0)!, period: .today)
        XCTAssertEqual(report.currencies.first?.values["revenue"], Decimal(string: "12.34"))
        XCTAssertEqual(report.currencies.first?.values["orders"], 2)
        XCTAssertEqual(report.currencies.first?.values["aov"], Decimal(string: "6.17"))
        XCTAssertFalse(IntegrationHTTP.validShop("store.myshopify.com.evil.test")); XCTAssertFalse(IntegrationHTTP.validShop("store.myshopify.com:443"))
        XCTAssertTrue(IntegrationHTTP.validShop("test-shop.myshopify.com"))
    }
    func testCodexRepeatedQuotaEventsDoNotDoubleCountLastTokens() throws {
        func row(total: Int, last: Int) -> [String: Any] { ["timestamp": "2026-10-08T01:00:00Z", "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": total, "output_tokens": 5], "last_token_usage": ["input_tokens": last, "output_tokens": 5]]]] }
        let lines = try [row(total: 100, last: 100), row(total: 100, last: 100), row(total: 120, last: 20)].map { try data($0) }
        let combined = lines.reduce(Data()) { $0 + $1 + Data([10]) }
        let report = AIAdapters.parseJSONL(combined, provider: .codex, session: "synthetic-hash")
        XCTAssertEqual(report.activity.reduce(0) { $0 + $1.input }, 120)
        XCTAssertEqual(report.activity.reduce(0) { $0 + $1.output }, 5)
    }
    func testClaudeStreamingDuplicateAndPrivateFieldsExcluded() throws {
        let row: [String: Any] = ["timestamp": "2026-10-08T01:00:00Z", "type": "assistant", "message": ["id": "synthetic-id", "usage": ["input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 40], "content": [["type": "text", "text": "DO_NOT_RETAIN_PRIVATE_TEXT"], ["type": "tool_use", "input": ["secret": "DO_NOT_RETAIN_PRIVATE_TEXT"]]]]]
        let line = try data(row), report = AIAdapters.parseJSONL(line + Data([10]) + line, provider: .claude, session: "hash")
        XCTAssertEqual(report.activity.count, 1); XCTAssertEqual(report.activity.first?.input, 140); XCTAssertEqual(report.activity.first?.tools, 1)
        XCTAssertFalse(String(data: try JSONEncoder().encode(report), encoding: .utf8)!.contains("DO_NOT_RETAIN_PRIVATE_TEXT"))
    }
    func testStatusLineDoesNotConfuseContextWithAccountQuota() {
        XCTAssertTrue(AIAdapters.statusReport(["context_window": ["used_percentage": 99]], provider: .claude).allowances.isEmpty)
        let claude = AIAdapters.statusReport(["rate_limits": ["five_hour": ["used_percentage": 25, "resets_at": stamp.timeIntervalSince1970]]], provider: .claude)
        XCTAssertEqual(claude.allowances.first?.usedPercent, 25); XCTAssertEqual(claude.allowances.first?.windowMinutes, 300)
        let agy = AIAdapters.statusReport(["quota": ["model-pool": ["remaining_fraction": 0.6, "reset_time": "2026-10-08T10:00:00Z"]]], provider: .antigravity)
        XCTAssertEqual(agy.allowances.first?.usedPercent ?? 0, 40, accuracy: 0.0001)
    }
    func testGeminiQuotaUsesFractionNotRemainingAmountAsPercent() throws {
        let report = try AIAdapters.geminiReport(["buckets": [["modelId": "synthetic-model", "remainingFraction": 0.8, "remainingAmount": "800", "resetTime": "2026-10-09T00:00:00Z"]]])
        XCTAssertEqual(report.allowances.first?.usedPercent ?? -1, 20, accuracy: 0.0001)
        XCTAssertThrowsError(try AIAdapters.geminiReport(["buckets": [["remainingAmount": "800"]]]))
    }
    func testGrokUsesIncludedCreditsExcludesPurchasedAndOnDemand() throws {
        let report = try AIAdapters.grokReport(["config": ["creditUsagePercent": 35, "currentPeriod": ["end": "2026-10-10T00:00:00Z"], "onDemandUsed": ["val": 500], "onDemandCap": ["val": 1000], "prepaidBalance": ["val": 10000]]])
        XCTAssertEqual(report.allowances.count, 1); XCTAssertEqual(report.allowances.first?.usedPercent, 35)
    }
    func testCopilotUnlimitedAndZeroPlaceholdersCannotBecomeFullAllowance() throws {
        let object: [String: Any] = ["quota_snapshots": ["chat": ["unlimited": true, "entitlement": 100, "percent_remaining": 100], "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 100]]]
        XCTAssertThrowsError(try AIAdapters.copilotQuotaReport(object))
        let report = try AIAdapters.copilotQuotaReport(["quota_reset_date": "2026-11-01", "quota_snapshots": ["premium_interactions": ["entitlement": 300, "remaining": 240, "unlimited": false]]])
        XCTAssertEqual(report.allowances.first?.usedPercent, 20)
    }
    func testCursorSeparatePoolsAndCostUnits() throws {
        let quota = try AIAdapters.cursorQuotaReport(["billingCycleEnd": "2026-11-01T00:00:00Z", "individualUsage": ["plan": ["autoPercentUsed": 12.5, "apiPercentUsed": 55.0]]])
        XCTAssertEqual(quota.allowances.map(\.usedPercent), [12.5, 55])
        let events = try AIAdapters.cursorActivity([["timestamp": stamp.timeIntervalSince1970 * 1000, "requestsCosts": 1, "tokenUsage": ["inputTokens": 100, "outputTokens": 20, "cacheReadTokens": 40, "totalCents": 12.5]]])
        XCTAssertEqual(events.first?.input, 140); XCTAssertEqual(events.first?.costUSD, 0.125)
    }
    func testExplicitImportRejectsUnknownSchemasAndExpiredLogin() throws {
        XCTAssertThrowsError(try AIAdapters.imported(data(["version": 2, "provider": "codex"]), provider: .codex))
        XCTAssertThrowsError(try IntegrationLogin.validToken("synthetic-token", expiry: .distantPast))
        XCTAssertThrowsError(try IntegrationLogin.validToken("bad\nheader", expiry: .distantFuture))
    }
    func testStockSparseYahooSeriesPreservesVolumeAndCurrency() throws {
        let object: [String: Any] = ["chart": ["error": NSNull(), "result": [["meta": ["currency": "JPY", "shortName": "Synthetic security"], "timestamp": [stamp.timeIntervalSince1970, stamp.timeIntervalSince1970 + 60, stamp.timeIntervalSince1970 + 120], "indicators": ["quote": [["close": [10, NSNull(), 12], "volume": [100, 200, 300]]]]]]]]
        let report = try StockAdapters.yahooReport(object, symbol: "SYNTH", range: "1d")
        XCTAssertEqual(report.points.count, 2); XCTAssertEqual(report.current, 12); XCTAssertEqual(report.points.last?.volume, 300); XCTAssertEqual(report.currency, "JPY")
        XCTAssertFalse(StockAdapters.validSymbol("SYMBOL/../../auth"))
    }
    func testAlphaMaximumRangeRetainsReturnedHistoryWithoutInventingCurrency() throws {
        let object: [String: Any] = ["Meta Data": ["5. Time Zone": "US/Eastern"], "Time Series (Daily)": ["2026-10-07": ["4. close": "100.25", "5. volume": "500"], "2020-01-02": ["4. close": "50", "5. volume": "100"]]]
        let report = try StockAdapters.alphaReport(object, symbol: "SYNTH", range: "max")
        XCTAssertEqual(report.points.count, 2); XCTAssertEqual(report.currency, ""); XCTAssertEqual(report.current, 100.25)
    }
    func testCopilotSDKOfficialQuotaAndUnlimitedSchemas() throws {
        let report = try AIAdapters.copilotSDKQuotaReport(["quotaSnapshots": ["premium_interactions": ["isUnlimitedEntitlement": false, "entitlementRequests": 300, "usedRequests": 30, "remainingPercentage": 90, "resetDate": "2026-11-01T00:00:00Z"], "chat": ["isUnlimitedEntitlement": true, "entitlementRequests": -1, "usedRequests": 2000, "remainingPercentage": 100]]])
        XCTAssertEqual(report.allowances.count, 1); XCTAssertEqual(report.allowances.first?.usedPercent, 10)
    }
    func testCopilotRPCFramingHandlesFragmentationAndMultipleFrames() throws {
        let first = try CopilotRPCFrame.encode(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 3]])
        let second = try CopilotRPCFrame.encode(["jsonrpc": "2.0", "id": 2, "result": ["quotaSnapshots": [:]]])
        var buffer = Data(first.prefix(12)); XCTAssertNil(try CopilotRPCFrame.next(&buffer))
        buffer.append(first.dropFirst(12)); buffer.append(second)
        XCTAssertEqual(try CopilotRPCFrame.next(&buffer)?["id"] as? Int, 1)
        XCTAssertEqual(try CopilotRPCFrame.next(&buffer)?["id"] as? Int, 2)
        XCTAssertTrue(buffer.isEmpty)
        var oversized = Data("Content-Length: 999999999\r\n\r\n".utf8)
        XCTAssertThrowsError(try CopilotRPCFrame.next(&oversized))
    }
    func testMalformedHugeNumbersCannotOverflowActivityOrPercent() throws {
        XCTAssertEqual(IntegrationNumber.saturatedSum([Int64.max, 1, -5]), Int64.max)
        XCTAssertEqual(IntegrationNumber.saturatedSum(Array(repeating: 9_000_000_000_000_000, count: 2000)), Int64.max)
        let event = AIActivityRecord(id: "fixture", session: "fixture", date: stamp, input: Int64.max, output: Int64.max)
        XCTAssertEqual(event.tokens, Int64.max)
        XCTAssertNil(IntegrationNumber.percent(1e300)); XCTAssertNil(IntegrationNumber.quantity(1e300)); XCTAssertNil(IntegrationNumber.date(1e300)); XCTAssertNil(IntegrationNumber.decimal("NaN"))
        XCTAssertThrowsError(try AIAdapters.grokReport(["config": ["creditUsagePercent": 1e300]]))
        let cursor = try AIAdapters.cursorQuotaReport(["individualUsage": ["plan": ["autoPercentUsed": 1e300, "apiPercentUsed": -1]]])
        XCTAssertTrue(cursor.allowances.isEmpty)
        XCTAssertEqual(IntegrationNumber.percent(120), 100)
    }
    func testCopilotQuotaCommandWithSyntheticServerCreatesNoSession() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("Fixture transport needs system Python") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opendock-rpc-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("quota-fixture")
        let script = #"""
        #!/usr/bin/python3
        import sys,json
        while True:
            line=sys.stdin.buffer.readline()
            if not line:break
            if not line.lower().startswith(b'content-length:'):sys.exit(3)
            length=int(line.split(b':',1)[1]);sys.stdin.buffer.readline()
            row=json.loads(sys.stdin.buffer.read(length));method=row.get('method')
            if method=='connect':result={'protocolVersion':3}
            elif method=='account.getQuota':result={'quotaSnapshots':{'premium_interactions':{'isUnlimitedEntitlement':False,'entitlementRequests':300,'usedRequests':60,'remainingPercentage':80}}}
            else:sys.exit(4)
            body=json.dumps({'jsonrpc':'2.0','id':row['id'],'result':result}).encode()
            sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(body)).encode()+body);sys.stdout.buffer.flush()
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let response = try await CopilotCLIQuotaCommand.read(executable: executable.path)
        let report = try AIAdapters.copilotSDKQuotaReport(response)
        XCTAssertEqual(report.allowances.first?.usedPercent, 20)
    }
}
