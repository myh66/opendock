import XCTest
@testable import OpenDock

final class OllamaWidgetTests: XCTestCase {
    func testSafeIncompleteAddressDraftsRemainPersistable() {
        for draft in ["", "h", "http:", "http://", "http://127.0.0.", "http://127.0.0.1:", "http://localhost:11434", "http://[::1]:11434"] {
            XCTAssertTrue(OllamaWidgetEndpoint.draftCanPersist(draft), draft)
        }
    }
    func testSensitiveAndMalformedAddressDraftsNeverPersist() {
        let drafts = ["http://synthetic-user:synthetic-secret@127.0.0.1:11434", "http://127.0.0.1:11434?token=synthetic-secret",
                      "http://127.0.0.1:11434#synthetic-secret", "synthetic-user@broken[", "bad[/?token=synthetic-secret",
                      "http://[broken", "http://127.0.0.1/%40synthetic-secret", "http://127.0.0.1\\@evil.test",
                      "http://127.0.0.1\n", String(repeating: "x", count: 513) + "@synthetic-secret"]
        for draft in drafts { XCTAssertFalse(OllamaWidgetEndpoint.draftCanPersist(draft), draft) }
    }
    func testImportedEndpointSecretsAreRemovedFromConfiguration() throws {
        let privateMarker = "SYNTHETIC_DO_NOT_SERIALIZE"
        let incoming = ["ollamaEndpoint": "http://user:\(privateMarker)@127.0.0.1:11434", "ollamaEndpointDraft": "http://127.0.0.1:11434?token=\(privateMarker)", "unrelated": "preserve"]
        let safe = OllamaWidgetEndpoint.sanitizedConfiguration(incoming)
        XCTAssertNil(safe["ollamaEndpoint"]); XCTAssertNil(safe["ollamaEndpointDraft"]); XCTAssertEqual(safe["unrelated"], "preserve")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(safe), as: UTF8.self).contains(privateMarker))
        let normal = ["ollamaEndpoint": "http://localhost:11434", "ollamaEndpointDraft": "http://127.0.0."]
        XCTAssertEqual(OllamaWidgetEndpoint.sanitizedConfiguration(normal), normal)
    }
    func testEndpointAllowsLiteralLoopbackAndNormalizesLocalhost() throws {
        XCTAssertEqual(try OllamaWidgetEndpoint(" http://localhost:11434/ ").url.absoluteString, "http://127.0.0.1:11434")
        XCTAssertEqual(try OllamaWidgetEndpoint("https://127.0.0.1:443").url.host, "127.0.0.1")
        let ipv6 = try OllamaWidgetEndpoint("http://[::1]:11434")
        XCTAssertEqual(try ipv6.api("ps").path, "/api/ps")
    }
    func testEndpointRejectsExternalHostsCredentialsAndAmbiguousURLs() {
        let rejected = ["http://0.0.0.0:11434", "http://192.168.1.2:11434", "http://127.0.0.2:11434",
                        "http://127.1:11434", "http://2130706433:11434", "http://localhost.evil.test:11434",
                        "http://user:secret@127.0.0.1:11434", "http://127.0.0.1:11434/api", "http://127.0.0.1:11434?token=secret",
                        "http://127.0.0.1:11434#x", "http://127.0.0.1:0", "http://127.0.0.1:65536", "file://localhost/",
                        "http://%31%32%37.0.0.1:11434", "http://127.0.0.1\\@evil.test", "http://[::ffff:127.0.0.1]:11434"]
        for url in rejected { XCTAssertThrowsError(try OllamaWidgetEndpoint(url), url) }
    }
    func testOnlyReadOnlyResourcesAreConstructible() throws {
        let endpoint = try OllamaWidgetEndpoint("http://127.0.0.1:11434")
        for name in ["tags", "ps", "version"] { XCTAssertEqual(try endpoint.api(name).path, "/api/" + name) }
        for name in ["generate", "pull", "delete", "../tags", "tags?x=1"] { XCTAssertThrowsError(try endpoint.api(name)) }
    }
    func testParsesOfficialTagsAndRunningModelFields() throws {
        let fixture = Data(#"{"models":[{"name":"synthetic-model:latest","model":"synthetic-model:latest","size":4683075271,"size_vram":4000000000,"context_length":8192,"details":{"family":"synthetic","parameter_size":"7B","quantization_level":"Q4_K_M"},"modified_at":"2026-10-08T01:02:03.123456789Z","expires_at":"2026-10-09T02:03:04Z"}]}"#.utf8)
        let models = try OllamaWidgetParser.models(fixture)
        XCTAssertEqual(models.count, 1); XCTAssertEqual(models.first?.name, "synthetic-model:latest")
        XCTAssertEqual(models.first?.bytes, 4_683_075_271); XCTAssertEqual(models.first?.vramBytes, 4_000_000_000)
        XCTAssertEqual(models.first?.contextLength, 8192); XCTAssertEqual(models.first?.parameters, "7B")
        XCTAssertNotNil(models.first?.modifiedAt); XCTAssertNotNil(models.first?.expiresAt)
        XCTAssertEqual(try OllamaWidgetParser.version(Data(#"{"version":"0.synthetic"}"#.utf8)), "0.synthetic")
    }
    func testEmptyModelListIsRealEmptyButMissingListIsError() throws {
        XCTAssertTrue(try OllamaWidgetParser.models(Data(#"{"models":[]}"#.utf8)).isEmpty)
        for raw in ["{}", #"{"error":"synthetic server error"}"#, #"{"models":null}"#, #"{"models":[{}]}"#] {
            XCTAssertThrowsError(try OllamaWidgetParser.models(Data(raw.utf8)))
        }
        let fallback = try OllamaWidgetParser.models(Data(#"{"models":[{"model":"synthetic-fallback"}]}"#.utf8))
        XCTAssertNil(fallback.first?.bytes); XCTAssertNil(fallback.first?.expiresAt)
    }
    func testMalformedNumbersDatesTextAndDuplicateIDsFailSoft() {
        let raws = [#"{"models":[{"name":"synthetic","size":-1}]}"#,
                    #"{"models":[{"name":"synthetic","size":18446744073709551616}]}"#,
                    #"{"models":[{"name":"synthetic","size":1.5}]}"#,
                    #"{"models":[{"name":"synthetic","expires_at":"not-a-date"}]}"#,
                    #"{"models":[{"name":"bad\nname"}]}"#,
                    #"{"models":[{"name":"same"},{"name":"same"}]}"#]
        for raw in raws { XCTAssertThrowsError(try OllamaWidgetParser.models(Data(raw.utf8))) }
        XCTAssertThrowsError(try OllamaWidgetParser.version(Data(#"{"version":""}"#.utf8)))
    }
    func testResponseLimitsAndFreshnessDoNotBecomeZeroOrLive() {
        XCTAssertThrowsError(try OllamaWidgetParser.validateSize(0))
        XCTAssertNoThrow(try OllamaWidgetParser.validateSize(OllamaWidgetParser.maximumBytes))
        XCTAssertThrowsError(try OllamaWidgetParser.validateSize(OllamaWidgetParser.maximumBytes + 1))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = OllamaWidgetReport(endpoint: "synthetic", version: "synthetic", installed: [], running: [], fetchedAt: now)
        XCTAssertFalse(report.isStale(at: now.addingTimeInterval(60)))
        XCTAssertTrue(report.isStale(at: now.addingTimeInterval(61)))
    }
}
