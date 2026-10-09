import XCTest
@testable import OpenDock

final class ShadowrocketTests: XCTestCase {
    func testLoopbackProxyDoesNotClaimShadowrocketConnection() throws {
        let summary = ShadowrocketProxySummary.parse(["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 1082,
                                                      "SOCKSEnable": 1, "SOCKSProxy": "::1", "SOCKSPort": 1080])
        XCTAssertTrue(summary.available)
        XCTAssertTrue(summary.isConfigured)
        XCTAssertEqual(summary.endpoints.map(\.address), ["127.0.0.1:1082", "[::1]:1080"])
        XCTAssertTrue(summary.endpoints.allSatisfy(\.isLoopback))
        let status = ShadowrocketStatusSnapshot(applicationURL: URL(fileURLWithPath: "/Applications/Synthetic.app"), clientRunning: true, proxies: summary, sampledAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(status.clientSummary, "客户端已运行")
        XCTAssertEqual(status.connectionSummary, "连接状态无法确认")
        XCTAssertEqual(ShadowrocketStatusSnapshot(proxies: summary, sampledAt: .now).connectionSummary, status.connectionSummary)
    }

    func testDisabledAndUnavailableSettingsRemainDistinct() {
        let unavailable = ShadowrocketProxySummary.parse(nil)
        XCTAssertFalse(unavailable.available)
        XCTAssertFalse(unavailable.isConfigured)
        let disabled = ShadowrocketProxySummary.parse(["HTTPEnable": 0, "HTTPProxy": "localhost", "HTTPPort": 1082])
        XCTAssertTrue(disabled.available)
        XCTAssertTrue(disabled.endpoints.isEmpty)
        XCTAssertFalse(disabled.isConfigured)
        XCTAssertNotEqual(unavailable.summary, disabled.summary)
        let malformed = ShadowrocketProxySummary.parse(["HTTPEnable": "yes", "SOCKSEnable": -1])
        XCTAssertTrue(malformed.hasUnknownFlags)
        XCTAssertNotEqual(malformed.summary, disabled.summary)
    }

    func testInvalidPortsAndCredentialURLsNeverAppearAsEndpoints() {
        for port: Any in [0, 65536, Double.nan, 3.5, true, "1082"] {
            let endpoint = ShadowrocketProxySummary.parse(["HTTPEnable": 1, "HTTPProxy": "localhost", "HTTPPort": port]).endpoints.first
            XCTAssertNil(endpoint?.port)
            XCTAssertEqual(endpoint?.address, "地址不可用")
        }
        let credential = ShadowrocketProxySummary.parse(["HTTPEnable": 1, "HTTPProxy": "http://username:secret@localhost/path?key=secret", "HTTPPort": 1082])
        XCTAssertNil(credential.endpoints.first?.host)
        XCTAssertFalse(credential.endpoints.first?.address.contains("secret") ?? true)
    }

    func testAutomaticConfigurationIsNotFetchedOrRetained() {
        let summary = ShadowrocketProxySummary.parse(["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://localhost/pac?token=synthetic-secret",
                                                      "ProxyAutoConfigJavaScript": "synthetic-script-secret", "ProxyAutoDiscoveryEnable": 1])
        XCTAssertTrue(summary.automaticConfiguration)
        XCTAssertTrue(summary.automaticDiscovery)
        XCTAssertTrue(summary.isConfigured)
        XCTAssertTrue(summary.endpoints.isEmpty)
        XCTAssertFalse(String(describing: summary).contains("synthetic-secret"))
        XCTAssertFalse(String(describing: summary).contains("synthetic-script-secret"))
    }

    func testOnlyLiteralLoopbackHostsAreIdentifiedAsLocal() {
        XCTAssertTrue(ShadowrocketProxyEndpoint(kind: "HTTP", host: "localhost.", port: 1082).isLoopback)
        XCTAssertTrue(ShadowrocketProxyEndpoint(kind: "HTTP", host: "127.3.4.5", port: 1082).isLoopback)
        XCTAssertFalse(ShadowrocketProxyEndpoint(kind: "HTTP", host: "127.999.1.1", port: 1082).isLoopback)
        XCTAssertFalse(ShadowrocketProxyEndpoint(kind: "HTTP", host: "localhost.example.com", port: 1082).isLoopback)
        XCTAssertFalse(ShadowrocketProxyEndpoint(kind: "HTTP", host: "192.0.2.2", port: 1082).isLoopback)
    }
}
