import XCTest
import SQLite3
@testable import OpenDock

final class ClaudeDesktopTests: XCTestCase {
    private let synthetic = "sk-ant-sid01-OpenDockSyntheticFixtureOnly123456789"
    private func bytes(_ hex: String) -> Data {
        var data = Data(), index = hex.startIndex
        while index < hex.endIndex { let end = hex.index(index, offsetBy: 2); data.append(UInt8(hex[index..<end], radix: 16)!); index = end }
        return data
    }

    // Ciphertexts generated independently with hashlib.pbkdf2_hmac and openssl,
    // using only this synthetic password/value. No personal cookie is accessed.
    func testChromiumKeyAndDomainBoundCookieAgainstIndependentVector() throws {
        let key = try ClaudeCookieCrypto.deriveKey(password: Data("OpenDock-fixture-password".utf8))
        XCTAssertEqual(key, bytes("2ff89363b1ad37a158ac8bbfe7fa75db"))
        let cipher = bytes("763130ac14d6b3bc0327d0b7cc33ffbd0a7a9348472529971e9d4a7cd04a2cd4fddf5f654c91f0153792e9d71d748ebea5576f76827b27e5305ff90ba58c3aff8ca5bbb0cade04fc8bebcf268e68151695d269fa7dda375934d3fdfa8f0b5971887f95")
        XCTAssertEqual(try ClaudeCookieCrypto.decrypt(cipher, key: key, host: ".claude.ai", databaseVersion: 24), synthetic)
        XCTAssertThrowsError(try ClaudeCookieCrypto.decrypt(cipher, key: key, host: "claude.ai", databaseVersion: 24))
        XCTAssertThrowsError(try ClaudeCookieCrypto.decrypt(cipher, key: key, host: "lookalike-claude.ai", databaseVersion: 24))
        XCTAssertThrowsError(try ClaudeCookieCrypto.decrypt(cipher, key: key, host: ".claude.ai", databaseVersion: 25))
    }

    func testLegacyCookieAndUnsupportedCipherAreDistinct() throws {
        let key = bytes("2ff89363b1ad37a158ac8bbfe7fa75db")
        let cipher = bytes("763130f906e222a2cbbf5708f3364a97971252b5716232a84c06998176977c74e437646913a887907331d0228b3d939b348fef11ca7bd2c11775965e3fe7300da29af8")
        XCTAssertEqual(try ClaudeCookieCrypto.decrypt(cipher, key: key, host: ".claude.ai", databaseVersion: 23), synthetic)
        var unknown = cipher; unknown[2] = Character("2").asciiValue!
        XCTAssertThrowsError(try ClaudeCookieCrypto.decrypt(unknown, key: key, host: ".claude.ai", databaseVersion: 23))
        XCTAssertThrowsError(try ClaudeCookieCrypto.decrypt(cipher, key: Data(repeating: 0, count: 16), host: ".claude.ai", databaseVersion: 23))
    }

    func testSessionRejectsAmbiguityExpiredAndHeaderInjection() throws {
        let row = ClaudeDesktopCookieRow(host: ".claude.ai", name: "sessionKey", value: synthetic, encrypted: Data(), expires: nil)
        XCTAssertEqual(try ClaudeDesktopCookies.session(rows: [row], key: nil, databaseVersion: 24).sessionKey, synthetic)
        var different = row; different.value += "different"
        XCTAssertThrowsError(try ClaudeDesktopCookies.session(rows: [row, different], key: nil, databaseVersion: 24))
        var expired = row; expired.expires = .distantPast
        XCTAssertThrowsError(try ClaudeDesktopCookies.session(rows: [expired], key: nil, databaseVersion: 24))
        var injected = row; injected.value += "\r\nX-Header: content"
        XCTAssertThrowsError(try ClaudeDesktopCookies.session(rows: [injected], key: nil, databaseVersion: 24))
    }

    func testSQLiteReadsOnlySelectedNamesAndLeavesFixtureUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenDock-Claude-Fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let script = """
        CREATE TABLE meta(key TEXT,value INTEGER);
        INSERT INTO meta VALUES('version',24);
        CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,expires_utc INTEGER,is_persistent INTEGER,path TEXT);
        INSERT INTO cookies VALUES('.claude.ai','sessionKey','\(synthetic)',X'',0,0,'/');
        INSERT INTO cookies VALUES('.claude.ai','lastActiveOrg','12345678-1234-1234-1234-123456789abc',X'',0,0,'/');
        INSERT INTO cookies VALUES('.claude.ai','unrelated','private-content',X'',0,0,'/');
        INSERT INTO cookies VALUES('.example.com','sessionKey','unrelated-value',X'',0,0,'/');
        """
        XCTAssertEqual(sqlite3_exec(db, script, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let before = try Data(contentsOf: file)
        let snapshot = try ClaudeDesktopCookies.read(file)
        XCTAssertEqual(snapshot.version, 24)
        XCTAssertEqual(Set(snapshot.rows.map(\.name)), Set(["sessionKey", "lastActiveOrg"]))
        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-shm"))
        XCTAssertNotNil(try ClaudeDesktopCookies.session(rows: snapshot.rows, key: nil, databaseVersion: snapshot.version).organization)
    }

    func testQuotaParserAcceptsZeroAndRejectsMissingOrNonfinite() throws {
        let date = Date(timeIntervalSince1970: 100)
        let report = try ClaudeDesktopUsage.parseUsage(["five_hour": ["utilization": 0, "resets_at": "2026-10-08T10:00:00Z"],
                                                       "seven_day": ["utilization": 32.5], "email": "not-retained", "transcript": "not-retained"], now: date)
        XCTAssertEqual(report.allowances.map(\.usedPercent), [0, 32.5])
        XCTAssertEqual(report.updatedAt, date)
        XCTAssertTrue(report.activity.isEmpty)
        XCTAssertThrowsError(try ClaudeDesktopUsage.parseUsage(["five_hour": ["utilization": "nan"]]))
        XCTAssertThrowsError(try ClaudeDesktopUsage.parseUsage([:]))
    }
}
