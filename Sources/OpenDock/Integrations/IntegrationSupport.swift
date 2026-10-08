import Foundation
import Security
import CryptoKit
import LocalAuthentication

enum IntegrationError: LocalizedError {
    case invalid(String), http(Int), incomplete, noData, keychain(OSStatus), schema
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .http(let status):
            switch status {
            case 401, 403: return "连接未获授权（HTTP \(status)）。请检查只读权限、账号、环境与密钥有效期。"
            case 429: return "服务请求过于频繁。请稍后刷新，或延长自动刷新间隔。"
            default: return "服务请求失败（HTTP \(status)）。已保留上次成功的数据。"
            }
        case .incomplete: return "报告超过安全读取上限，无法显示完整总额。请缩短日期范围。"
        case .noData: return "尚无可读取的数据；这不表示用量或额度为零。"
        case .keychain(let status): return "钥匙串操作失败（\(status)），请检查应用访问权限。"
        case .schema: return "服务响应不符合已支持的数据格式，未生成推测数字。"
        }
    }
}

enum IntegrationPeriod: String, CaseIterable, Identifiable, Codable {
    case today, l7, l30, mtd
    var id: String { rawValue }
    var title: String { switch self { case .today: return "Today"; case .l7: return "L7"; case .l30: return "L30"; case .mtd: return "MTD" } }
    func interval(at now: Date = .now, timeZone: TimeZone = .current) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: now)
        let start: Date
        switch self {
        case .today: start = day
        case .l7: start = calendar.date(byAdding: .day, value: -6, to: day) ?? day
        case .l30: start = calendar.date(byAdding: .day, value: -29, to: day) ?? day
        case .mtd: start = calendar.dateInterval(of: .month, for: now)?.start ?? day
        }
        return DateInterval(start: start, end: now)
    }
}

struct IntegrationPoint: Codable, Identifiable, Equatable {
    var date: Date
    var value: Double
    var volume: Double?
    var id: Date { date }
}
struct BusinessCurrency: Codable, Equatable {
    var currency: String
    var values: [String: Decimal] = [:]
    var series: [String: [IntegrationPoint]] = [:]
    var products: [String: Double] = [:]
    var channels: [String: Double] = [:]
}
struct BusinessReport: Codable, Equatable {
    var currencies: [BusinessCurrency]
    var fetchedAt: Date
    var source: String
    var note: String
    var period: String
}
struct StockReport: Codable, Equatable {
    var symbol: String
    var name: String
    var currency: String
    var points: [IntegrationPoint]
    var fetchedAt: Date
    var source: String
    var range: String
    var note: String = ""
    var current: Double? { points.last?.value }
}

enum IntegrationNumber {
    static func finite(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { number = value.doubleValue }
        else if let value = value as? String { number = Double(value) }
        else { number = nil }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
    static func count(_ value: Any?) -> Int64 {
        guard let number = finite(value), number >= 0, number <= 9_000_000_000_000_000 else { return 0 }
        return Int64(number)
    }
    static func saturatedSum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { total, next in
            let sum = total.addingReportingOverflow(max(0, next))
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }
    static func quantity(_ value: Any?) -> Double? { finite(value).flatMap { (0...9_000_000_000_000_000).contains($0) ? $0 : nil } }
    static func percent(_ value: Any?) -> Double? { finite(value).flatMap { (0...1_000_000).contains($0) ? min(100, $0) : nil } }
    static func decimal(_ value: Any?) -> Decimal? {
        let result: Decimal?
        if let string = value as? String, string.count < 100, string.range(of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil { result = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) }
        else if let number = value as? NSNumber, finite(number) != nil { result = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) }
        else { result = nil }
        guard let result, NSDecimalNumber(decimal: result).doubleValue.isFinite, abs(NSDecimalNumber(decimal: result).doubleValue) <= 9_000_000_000_000_000 else { return nil }
        return result
    }
    static func major(_ minor: Decimal, currency: String) -> Decimal {
        let zero: Set<String> = ["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF"]
        let three: Set<String> = ["BHD", "JOD", "KWD", "OMR", "TND"]
        return minor / (zero.contains(currency.uppercased()) ? 1 : three.contains(currency.uppercased()) ? 1000 : 100)
    }
    static func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
    static func money(_ value: Decimal?, currency: String) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = currency
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value) \(currency)"
    }
    static func hash(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func date(_ value: Any?) -> Date? {
        if let seconds = finite(value), seconds > 0 {
            let epoch = seconds > 10_000_000_000 ? seconds / 1000 : seconds
            guard epoch <= 9_000_000_000 else { return nil }; return Date(timeIntervalSince1970: epoch)
        }
        guard let string = value as? String, string.count <= 100 else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        guard string.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = TimeZone(secondsFromGMT: 0); day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
        return day.date(from: string)
    }
}

enum IntegrationKeychain {
    private static let service = "io.github.myh66.opendock.integrations"
    static func save(_ values: [String: String], account: String) throws {
        let data = try JSONEncoder().encode(values)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var create = query; create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(create as CFDictionary, nil)
            guard result == errSecSuccess else { throw IntegrationError.keychain(result) }
        } else if update != errSecSuccess { throw IntegrationError.keychain(update) }
    }
    static func read(account: String, allowPrompt: Bool) throws -> [String: String]? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowPrompt { let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw IntegrationError.keychain(status) }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
    static func remove(account: String) throws {
        let result = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw IntegrationError.keychain(result) }
    }
}

struct IntegrationAccount: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: String
    var name: String
    var domain: String = ""
    var sandbox: Bool = false
    var colorHex: String? = nil
}
enum IntegrationDisk {
    static var root: URL {
        if ProcessInfo.processInfo.arguments.contains("--ui-test"),let path = ProcessInfo.processInfo.environment["OPENDOCK_TEST_ARCHIVE"] { return URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("integrations",isDirectory:true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenDock/integrations", isDirectory: true)
    }
    static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let url = root.appendingPathComponent(IntegrationNumber.hash(key) + ".json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 32_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, key: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent(IntegrationNumber.hash(key) + ".json")
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func remove(key: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(IntegrationNumber.hash(key) + ".json")) }
    static var accounts: [IntegrationAccount] { read([IntegrationAccount].self, key: "accounts") ?? [] }
    static func saveAccount(_ account: IntegrationAccount) throws {
        var list = accounts; list.removeAll { $0.id == account.id }; list.append(account); try write(list, key: "accounts")
    }
    static func removeAccount(_ account: IntegrationAccount) throws { try write(accounts.filter { $0.id != account.id }, key: "accounts") }
}

/// Never logs requests, credential-bearing URLs, headers, or response bodies.
/// Redirects are rejected to prevent forwarding service credentials to another host.
final class IntegrationHTTP: NSObject, URLSessionTaskDelegate {
    static let shared = IntegrationHTTP()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func json(_ url: URL, headers: [String: String] = [:], body: [String: Any]? = nil, form: [String: String]? = nil) async throws -> [String: Any] {
        let allowed: Set<String> = ["api.stripe.com", "api.paddle.com", "sandbox-api.paddle.com", "api.cursor.com", "cursor.com", "api.github.com", "cloudcode-pa.googleapis.com", "cli-chat-proxy.grok.com", "query1.finance.yahoo.com", "query2.finance.yahoo.com", "www.alphavantage.co"]
        guard url.scheme == "https", let host = url.host, allowed.contains(host) || Self.validShop(host) else { throw IntegrationError.invalid("不支持此服务地址。") }
        var request = URLRequest(url: url); request.setValue("OpenDock/0.1", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let form {
            var components = URLComponents(); components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpMethod = "POST"; request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw IntegrationError.schema }
            guard (200...299).contains(http.statusCode) else { throw IntegrationError.http(http.statusCode) }
            guard data.count <= 32_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IntegrationError.schema }
            return object
        } catch let error as IntegrationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw IntegrationError.invalid("网络请求未完成；请检查连接并重试。") }
    }
    static func url(_ base: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base) else { throw IntegrationError.schema }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw IntegrationError.schema }; return url
    }
    static func validShop(_ host: String) -> Bool { host.range(of: #"^[a-z0-9][a-z0-9-]*\.myshopify\.com$"#, options: .regularExpression) != nil }
}
