import XCTest
@testable import OpenDock

final class IBKRWidgetTests: XCTestCase {
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func testGatewayOnlyAllowsLocalHTTPSWithoutCredentialsOrRedirectTargets() throws {
        XCTAssertEqual(try IBKRReader.gateway(" https://localhost:5000/ ").absoluteString, "https://localhost:5000/v1/api")
        XCTAssertNoThrow(try IBKRReader.gateway("https://[::1]:5000/v1/api/"))
        for url in ["http://localhost:5000", "https://localhost.example.com", "https://127.0.0.2", "https://user:password@localhost:5000", "https://localhost:5000/v1/api?token=secret", "https://localhost:5000/other", "https://localhost:5000/#x", "https://localhost:0"] {
            XCTAssertThrowsError(try IBKRReader.gateway(url), url)
        }
        for id in ["", "../orders", "U12/34", "U123?x", String(repeating: "A", count: 65)] { XCTAssertFalse(IBKRReader.validAccount(id)) }
    }
    func testOrdinaryIncompleteGatewayDraftsRemainPersistableWithoutAuthorizingConnection() throws {
        for draft in ["", "https://", "https://localhost", "https://localhost:5000/v1/", "https://[::1]:5000/v1/api", "localhost", "ordinary address draft"] {
            XCTAssertTrue(IBKRReader.gatewayDraftCanPersist(draft), draft)
            let saved = IBKRReader.configurationBySavingGatewayDraft(draft, in: ["ibkrHideAmounts": "true"])
            XCTAssertEqual(saved["ibkrGateway"], draft)
            XCTAssertEqual(saved["ibkrHideAmounts"], "true")
        }
        XCTAssertThrowsError(try IBKRReader.gateway("ordinary address draft"))
        XCTAssertThrowsError(try IBKRReader.gateway("https://localhost:5000/v1/"))
    }
    func testSensitiveOrMalformedGatewayDraftsNeverReachExportableConfiguration() throws {
        let original = ["ibkrGateway": "https://localhost:5000/v1/api", "ibkrAccountID": "U10001", "ibkrHideAmounts": "true"]
        let dangerous = ["https://synthetic-user:synthetic-secret@localhost:5000/v1/api", "//synthetic-user:synthetic-secret@localhost",
                         "synthetic-user:synthetic-secret@localhost", "https://localhost:5000/v1/api?token=synthetic-secret",
                         "https://localhost:5000/v1/api#synthetic-secret", "https://[::1/?token=synthetic-secret", "https://[::1"]
        for draft in dangerous {
            XCTAssertFalse(IBKRReader.gatewayDraftCanPersist(draft), draft)
            let saved = IBKRReader.configurationBySavingGatewayDraft(draft, in: original)
            XCTAssertEqual(saved, original, "Rejecting a draft must preserve the last ordinary address and other settings")
            let exported = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
            XCTAssertFalse(exported.contains("synthetic-secret"))
        }
        let clean = IBKRReader.configurationBySavingGatewayDraft(dangerous[0], in: ["ibkrGateway": dangerous[0], "ibkrAccountID": "U10001"])
        XCTAssertNil(clean["ibkrGateway"], "An imported unsafe address must not be copied into the next configuration write")
        XCTAssertEqual(clean["ibkrAccountID"], "U10001")
        XCTAssertNil(IBKRReader.configurationBySavingGatewayDraft(dangerous[0], in: [:])["ibkrGateway"])
    }
    func testAccountsDeduplicateAndDoNotInventCurrency() throws {
        let data = try json([["accountId": "U10001", "accountAlias": "Synthetic", "currency": "EUR"], ["id": "U10001"], ["id": "DU90002"], ["id": "../bad"]])
        let accounts = try IBKRReader.accounts(data)
        XCTAssertEqual(accounts.map(\.id), ["U10001", "DU90002"])
        XCTAssertEqual(accounts[0].name, "Synthetic"); XCTAssertEqual(accounts[0].currency, "EUR")
        XCTAssertEqual(accounts[1].currency, ""); XCTAssertEqual(accounts[0].maskedID, "•••0001")
    }
    func testLedgerUsesBaseAggregateInsteadOfSummingCurrencyBuckets() throws {
        let data = try json(["BASE": ["currency": "BASE", "netliquidationvalue": "1200.5", "cashbalance": 400, "unrealizedpnl": -25], "USD": ["netliquidationvalue": 1000], "EUR": ["netliquidationvalue": 500]])
        let ledger = try IBKRReader.ledger(data, currency: "EUR")
        XCTAssertEqual(ledger.currency, "EUR"); XCTAssertEqual(ledger.netValue, 1200.5)
        XCTAssertEqual(ledger.cash, 400); XCTAssertEqual(ledger.unrealized, -25)
        XCTAssertThrowsError(try IBKRReader.ledger(try json(["error": "not logged in"]), currency: "USD"))
        // A currency bucket differs from BASE and must never masquerade as the total.
        XCTAssertThrowsError(try IBKRReader.ledger(try json(["USD": ["netliquidationvalue": 1000, "cashbalance": 300]]), currency: "USD"))
    }
    func testFinancialMissingAndInvalidValuesRemainUnavailable() throws {
        XCTAssertNil(IBKRReader.number(true)); XCTAssertNil(IBKRReader.number("NaN")); XCTAssertNil(IBKRReader.number("inf")); XCTAssertNil(IBKRReader.number(NSNull()))
        let ledger = try IBKRReader.ledger(try json(["BASE": ["currency": "BASE", "netliquidationvalue": true, "cashbalance": "bad"]]), currency: "")
        XCTAssertNil(ledger.netValue); XCTAssertNil(ledger.cash); XCTAssertNil(ledger.unrealized)
        let positions = try IBKRReader.positions(try json([["conid": 42, "contractDesc": "SYNTH", "position": -1.25, "currency": "JPY", "mktValue": "1200"], ["conid": 42, "model": "MODEL", "position": true]]))
        XCTAssertEqual(positions[0].quantity, -1.25); XCTAssertEqual(positions[0].marketValue, 1200)
        XCTAssertEqual(positions[0].currency, "JPY"); XCTAssertNil(positions[1].quantity)
        XCTAssertNotEqual(positions[0].id, positions[1].id)
        XCTAssertThrowsError(try IBKRReader.positions(try json(["error": "not authenticated"])))
        XCTAssertThrowsError(try IBKRReader.accounts(Data(repeating: 0, count: 2_000_001)))
    }
}
