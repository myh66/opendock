import Foundation
import Security
import CryptoKit
import CommonCrypto
import SQLite3

enum ClaudeDesktopError: LocalizedError {
    case connectRequired, invalidDatabase, unsupportedEncryption, invalidCookie, ambiguousSession, organizationRequired, decryptFailed, permission(OSStatus), network, http(Int)
    var errorDescription: String? {
        switch self {
        case .connectRequired: return "请手动连接 Claude Desktop，允许读取所选 Cookies 和 Claude Safe Storage。后台不会请求钥匙串权限。"
        case .invalidDatabase: return "所选文件不是受支持的 Claude Chromium Cookies 数据库，或正在写入。请在 Claude Desktop 登录后重新连接。"
        case .unsupportedEncryption: return "Claude Cookie 使用未支持的加密或数据库版本；未尝试其他密钥或猜测解密。"
        case .invalidCookie: return "所选 Claude Desktop 没有有效的 sessionKey。请先在 Claude Desktop 登录。"
        case .ambiguousSession: return "所选 Cookies 有多个不同会话，无法安全确定账号。请在 Claude Desktop 确定当前账号后重试。"
        case .organizationRequired: return "当前 Claude 会话有多个组织且没有有效 lastActiveOrg。请先在 Claude Desktop 选择组织。"
        case .decryptFailed: return "Claude Cookie 解密或域校验失败；未使用此数据发起请求。"
        case .permission(let code): return "Claude Safe Storage 读取未获允许（\(code)）。请手动重试连接。"
        case .network: return "Claude Desktop 额度请求未完成，请检查网络后手动刷新。"
        case .http(let code): return "Claude 客户端额度查询不可用（HTTP \(code)）；可能为会话过期、权限或网站挑战。请在 Claude Desktop 登录后重试。"
        }
    }
}

/// Original implementation of the documented Chromium v10 format. Protocol
/// references (no third-party implementation code copied):
/// chromium/chromium 131.0.6778.204 components/os_crypt/sync/os_crypt_mac.mm;
/// net/extras/sqlite/sqlite_persistent_cookie_store.cc (v24 domain binding);
/// Dockset's official manual/ai-usage documents explicit Desktop fallback.
/// The Claude Desktop session API is a non-stable client contract, not a public
/// Anthropic API; the format guard rejects unknown databases and ciphers.
enum ClaudeCookieCrypto {
    static func deriveKey(password: Data) throws -> Data {
        guard !password.isEmpty, password.count <= 4096 else { throw ClaudeDesktopError.decryptFailed }
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let length = key.count
        let result = password.withUnsafeBytes { buffer in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), buffer.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, length)
        }
        guard result == kCCSuccess else { throw ClaudeDesktopError.decryptFailed }
        return Data(key)
    }

    static func decrypt(_ encrypted: Data, key: Data, host: String, databaseVersion: Int) throws -> String {
        guard ["claude.ai", ".claude.ai"].contains(host), (23...24).contains(databaseVersion), key.count == kCCKeySizeAES128,
              encrypted.count > 3, encrypted.count <= 16_384, encrypted.prefix(3) == Data("v10".utf8) else { throw ClaudeDesktopError.unsupportedEncryption }
        let cipher = Data(encrypted.dropFirst(3)), iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        guard cipher.count % kCCBlockSizeAES128 == 0 else { throw ClaudeDesktopError.decryptFailed }
        var output = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128), written = 0
        let capacity = output.count
        let status = key.withUnsafeBytes { keyBytes in
            cipher.withUnsafeBytes { input in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                        iv, input.baseAddress, cipher.count, &output, capacity, &written)
            }
        }
        guard status == kCCSuccess else { throw ClaudeDesktopError.decryptFailed }
        var plain = Data(output.prefix(written))
        if databaseVersion >= 24 {
            let domain = Data(SHA256.hash(data: Data(host.utf8)))
            guard plain.count >= domain.count, plain.prefix(domain.count) == domain else { throw ClaudeDesktopError.decryptFailed }
            plain.removeFirst(domain.count)
        }
        guard let value = String(data: plain, encoding: .utf8), !value.isEmpty else { throw ClaudeDesktopError.decryptFailed }
        return value
    }
}

struct ClaudeDesktopCookieRow {
    var host: String
    var name: String
    var value: String
    var encrypted: Data
    var expires: Date?
}

enum ClaudeDesktopCookies {
    struct Session { let sessionKey: String; let organization: UUID? }

    static func session(rows: [ClaudeDesktopCookieRow], key: Data?, databaseVersion: Int, now: Date = .now) throws -> Session {
        var values: [String: Set<String>] = [:]
        for row in rows where ["claude.ai", ".claude.ai"].contains(row.host) && ["sessionKey", "lastActiveOrg"].contains(row.name) {
            if let expires = row.expires, expires <= now { continue }
            let value: String
            if !row.encrypted.isEmpty {
                guard row.value.isEmpty, let key else { throw ClaudeDesktopError.decryptFailed }
                value = try ClaudeCookieCrypto.decrypt(row.encrypted, key: key, host: row.host, databaseVersion: databaseVersion)
            } else { value = row.value }
            if !value.isEmpty { values[row.name, default: []].insert(value) }
        }
        guard let sessions = values["sessionKey"], !sessions.isEmpty else { throw ClaudeDesktopError.invalidCookie }
        guard sessions.count == 1, (values["lastActiveOrg"]?.count ?? 0) <= 1 else { throw ClaudeDesktopError.ambiguousSession }
        let session = sessions.first!
        guard session.hasPrefix("sk-ant-"), (16...4096).contains(session.utf8.count), session.utf8.allSatisfy({ byte in
            byte == 0x21 || (0x23...0x2B).contains(byte) || (0x2D...0x3A).contains(byte) || (0x3C...0x5B).contains(byte) || (0x5D...0x7E).contains(byte)
        }) else { throw ClaudeDesktopError.invalidCookie }
        return Session(sessionKey: session, organization: values["lastActiveOrg"]?.first.flatMap(UUID.init(uuidString:)))
    }

    /// Snapshot only a user-selected DB and its WAL. SQLite may create SHM in the
    /// temporary copy; it never opens the supplier database for writing. Nothing
    /// from the temporary copy is persisted after this call.
    static func read(_ selected: URL) throws -> (version: Int, rows: [ClaudeDesktopCookieRow]) {
        guard selected.isFileURL else { throw ClaudeDesktopError.invalidDatabase }
        let database = selected.resolvingSymlinksInPath()
        let values = try database.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 100_000_000 else { throw ClaudeDesktopError.invalidDatabase }
        let fm = FileManager.default, directory = fm.temporaryDirectory.appendingPathComponent("OpenDock-Claude-Cookies-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("Cookies")
        try fm.copyItem(at: database, to: copy)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        if fm.fileExists(atPath: wal.path) {
            let info = try wal.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 100_000_000 else { throw ClaudeDesktopError.invalidDatabase }
            let target = URL(fileURLWithPath: copy.path + "-wal"); try fm.copyItem(at: wal, to: target)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw ClaudeDesktopError.invalidDatabase
        }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version' LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let meta = statement else { throw ClaudeDesktopError.invalidDatabase }
        guard sqlite3_step(meta) == SQLITE_ROW else { sqlite3_finalize(meta); throw ClaudeDesktopError.invalidDatabase }
        let version = Int(sqlite3_column_int(meta, 0)); sqlite3_finalize(meta)
        guard (23...24).contains(version) else { throw ClaudeDesktopError.unsupportedEncryption }
        statement = nil
        let query = "SELECT host_key,name,value,encrypted_value,expires_utc,is_persistent FROM cookies WHERE host_key IN ('claude.ai','.claude.ai') AND name IN ('sessionKey','lastActiveOrg') AND path='/' LIMIT 9"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw ClaudeDesktopError.invalidDatabase }
        defer { sqlite3_finalize(statement) }
        func text(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
        var rows: [ClaudeDesktopCookieRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, rows.count < 8 else { throw ClaudeDesktopError.invalidDatabase }
            let length = Int(sqlite3_column_bytes(statement, 3))
            guard length <= 16_384 else { throw ClaudeDesktopError.invalidDatabase }
            let encrypted = sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: length) } ?? Data()
            let microseconds = sqlite3_column_int64(statement, 4)
            let expiry: Date? = sqlite3_column_int(statement, 5) != 0 && microseconds > 0 ? Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600) : nil
            rows.append(ClaudeDesktopCookieRow(host: text(0), name: text(1), value: text(2), encrypted: encrypted, expires: expiry))
        }
        return (version, rows)
    }
}

/// Explicit connection owns only an in-memory cookie. Background refresh cannot
/// read the supplier DB or Keychain. Restarting OpenDock needs manual connection.
actor ClaudeDesktopUsage {
    static let shared = ClaudeDesktopUsage()
    private struct Connection: Codable { let cookieDatabase: String }
    private var session: ClaudeDesktopCookies.Session?
    private var database: URL?
    private var report: AIReport?
    private var lastAttempt: Date?
    private var generation = UUID()
    private let http = ClaudeDesktopHTTP()

    nonisolated static func defaultCookieLocations() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        return [root.appendingPathComponent("Cookies"), root.appendingPathComponent("Network/Cookies")]
    }
    nonisolated static var selectedCookieDatabase: URL? {
        IntegrationDisk.read(Connection.self, key: "claude-desktop-connection").map { URL(fileURLWithPath: $0.cookieDatabase) }
    }
    nonisolated static var cachedReport: AIReport? { IntegrationDisk.read(AIReport.self, key: "claude-desktop-cache") }
    func isConnected() -> Bool { session != nil }

    func connect(cookieDatabase: URL) async throws -> AIReport {
        generation = UUID(); let token = generation
        session = nil; report = nil; lastAttempt = nil
        let imported = try await Task.detached(priority: .utility) { try Self.importSession(cookieDatabase) }.value
        guard token == generation else { throw CancellationError() }
        session = imported; database = cookieDatabase
        try IntegrationDisk.write(Connection(cookieDatabase: cookieDatabase.path), key: "claude-desktop-connection")
        return try await refresh(explicit: false, force: true)
    }
    func refresh(explicit: Bool) async throws -> AIReport { try await refresh(explicit: explicit, force: false) }
    private func refresh(explicit: Bool, force: Bool) async throws -> AIReport {
        let token = generation
        if explicit {
            guard let source = database ?? Self.selectedCookieDatabase else { throw ClaudeDesktopError.connectRequired }
            let previous = session?.sessionKey
            session = nil
            let imported = try await Task.detached(priority: .utility) { try Self.importSession(source) }.value
            guard token == generation else { throw CancellationError() }
            session = imported; database = source
            if previous != imported.sessionKey { report = nil; lastAttempt = nil }
        }
        guard let session else { throw ClaudeDesktopError.connectRequired }
        if !explicit, !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 300 {
            guard let report else { throw ClaudeDesktopError.network }; return report
        }
        lastAttempt = .now
        do {
            var organization = session.organization
            if organization == nil {
                let data = try await http.get(path: "/api/organizations", sessionKey: session.sessionKey)
                guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw IntegrationError.schema }
                let ids = objects.compactMap { ($0["uuid"] as? String).flatMap(UUID.init(uuidString:)) }
                guard ids.count == 1 else { throw ClaudeDesktopError.organizationRequired }; organization = ids[0]
            }
            let data = try await http.get(path: "/api/organizations/\(organization!.uuidString.lowercased())/usage", sessionKey: session.sessionKey)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IntegrationError.schema }
            let value = try Self.parseUsage(object)
            guard token == generation else { throw CancellationError() }
            report = value; try IntegrationDisk.write(value, key: "claude-desktop-cache")
            return value
        } catch {
            if case ClaudeDesktopError.http(401) = error, token == generation { self.session = nil }
            throw error
        }
    }
    func disconnect() {
        generation = UUID(); session = nil; database = nil; report = nil; lastAttempt = nil
        IntegrationDisk.remove(key: "claude-desktop-connection"); IntegrationDisk.remove(key: "claude-desktop-cache")
    }
    nonisolated static func parseUsage(_ object: [String: Any], now: Date = .now) throws -> AIReport {
        var windows: [AIAllowance] = []
        for name in ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"] {
            guard let row = object[name] as? [String: Any], let used = IntegrationNumber.finite(row["utilization"]), (0...100).contains(used) else { continue }
            windows.append(AIAllowance(id: "desktop." + name, usedPercent: used, resetsAt: IntegrationNumber.date(row["resets_at"]), windowMinutes: name == "five_hour" ? 300 : 10080))
        }
        guard !windows.isEmpty else { throw IntegrationError.noData }
        return AIReport(provider: .claude, allowances: windows, updatedAt: now, note: "Claude Desktop 现有会话客户端接口（非稳定公开 API）；所选组织额度。Cookie 仅在内存，后台不读钥匙串、不刷新登录；缓存只保存数值。")
    }
    nonisolated private static func importSession(_ source: URL) throws -> ClaudeDesktopCookies.Session {
        let saved = try ClaudeDesktopCookies.read(source)
        let needsKey = saved.rows.contains { !$0.encrypted.isEmpty }
        let key: Data?
        if needsKey {
            var result: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Claude Safe Storage",
                                       kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let password = result as? Data else { throw ClaudeDesktopError.permission(status) }
            key = try ClaudeCookieCrypto.deriveKey(password: password)
        } else { key = nil }
        return try ClaudeDesktopCookies.session(rows: saved.rows, key: key, databaseVersion: saved.version)
    }
}

private final class ClaudeDesktopHTTP: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func get(path: String, sessionKey: String) async throws -> Data {
        guard path == "/api/organizations" || path.range(of: #"^/api/organizations/[a-f0-9-]{36}/usage$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://claude.ai" + path) else { throw IntegrationError.schema }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("sessionKey=" + sessionKey, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenDock/0.2", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ClaudeDesktopError.network }
            guard response.statusCode == 200 else { throw ClaudeDesktopError.http(response.statusCode) }
            guard data.count <= 1_000_000 else { throw IntegrationError.incomplete }; return data
        } catch let error as ClaudeDesktopError { throw error }
        catch let error as IntegrationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ClaudeDesktopError.network }
    }
}
