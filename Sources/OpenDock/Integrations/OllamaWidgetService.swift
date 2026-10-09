import Foundation

enum OllamaWidgetError: LocalizedError {
    case endpoint, response, tooLarge, http(Int), unavailable
    var errorDescription: String? {
        switch self {
        case .endpoint: return "请输入本机回环地址，例如 http://127.0.0.1:11434；不要包含账号、路径或查询参数。"
        case .response: return "Ollama 响应格式无法识别；未推测模型状态。"
        case .tooLarge: return "Ollama 响应超过 4 MB，已停止读取。"
        case .http(let status): return "Ollama 返回 HTTP \(status)，请检查本机服务。"
        case .unavailable: return "无法读取本机 Ollama。请确认服务已启动，再手动刷新。"
        }
    }
}

/// Literal loopback hosts only: localhost is normalized so DNS/proxies cannot change the destination.
struct OllamaWidgetEndpoint: Equatable {
    let url: URL
    /// A draft may be incomplete while typing, but credential-bearing/ambiguous text never goes into layout JSON.
    static func draftCanPersist(_ input: String) -> Bool {
        guard input.utf8.count <= 512, !input.contains("%"), !input.contains("\\"),
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !input.contains("@"), !input.contains("?"), !input.contains("#") else { return false }
        guard let parts = URLComponents(string: input) else {
            return !input.contains("/")
        }
        return parts.user == nil && parts.password == nil && parts.query == nil && parts.fragment == nil
    }
    static func sanitizedConfiguration(_ configuration: [String: String]) -> [String: String] {
        var safe = configuration
        if let draft = safe["ollamaEndpointDraft"], !draftCanPersist(draft) { safe["ollamaEndpointDraft"] = nil }
        if let endpoint = safe["ollamaEndpoint"], (try? OllamaWidgetEndpoint(endpoint)) == nil { safe["ollamaEndpoint"] = nil }
        return safe
    }
    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 512, !text.contains("%"), !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host?.lowercased(),
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw OllamaWidgetError.endpoint }
        parts.scheme = scheme
        parts.host = host == "localhost" ? "127.0.0.1" : host
        parts.path = ""
        guard let url = parts.url else { throw OllamaWidgetError.endpoint }
        self.url = url
    }
    func api(_ resource: String) throws -> URL {
        guard ["tags", "ps", "version"].contains(resource) else { throw OllamaWidgetError.endpoint }
        return url.appendingPathComponent("api").appendingPathComponent(resource)
    }
}

struct OllamaWidgetModel: Identifiable, Equatable {
    var name: String
    var bytes: UInt64?
    var vramBytes: UInt64?
    var family: String?
    var parameters: String?
    var quantization: String?
    var modifiedAt: Date?
    var expiresAt: Date?
    var contextLength: UInt64?
    var id: String { name }
}

struct OllamaWidgetReport: Equatable {
    var endpoint: String
    var version: String
    var installed: [OllamaWidgetModel]
    var running: [OllamaWidgetModel]
    var fetchedAt: Date
    func isStale(at date: Date = .now) -> Bool { date.timeIntervalSince(fetchedAt) > 60 }
}

enum OllamaWidgetParser {
    static let maximumBytes = 4 * 1024 * 1024
    private struct Envelope: Decodable { var models: [Model] }
    private struct Version: Decodable { var version: String }
    private struct Details: Decodable {
        var family: String?
        var parameter_size: String?
        var quantization_level: String?
    }
    private struct Model: Decodable {
        var name: String?
        var model: String?
        var size: UInt64?
        var size_vram: UInt64?
        var details: Details?
        var modified_at: String?
        var expires_at: String?
        var context_length: UInt64?
    }
    static func validateSize(_ count: Int) throws {
        guard count > 0 else { throw OllamaWidgetError.response }
        guard count <= maximumBytes else { throw OllamaWidgetError.tooLarge }
    }
    static func version(_ data: Data) throws -> String {
        try validateSize(data.count)
        guard let value = try? JSONDecoder().decode(Version.self, from: data), validText(value.version) else { throw OllamaWidgetError.response }
        return value.version
    }
    static func models(_ data: Data) throws -> [OllamaWidgetModel] {
        try validateSize(data.count)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.models.count <= 2000 else { throw OllamaWidgetError.response }
        var names = Set<String>()
        return try envelope.models.map { record in
            guard let name = record.name ?? record.model, validText(name), names.insert(name).inserted else { throw OllamaWidgetError.response }
            let details = [record.details?.family, record.details?.parameter_size, record.details?.quantization_level].compactMap { $0 }
            guard details.allSatisfy(validText) else { throw OllamaWidgetError.response }
            return OllamaWidgetModel(name: name, bytes: record.size, vramBytes: record.size_vram,
                                     family: record.details?.family, parameters: record.details?.parameter_size,
                                     quantization: record.details?.quantization_level,
                                     modifiedAt: try date(record.modified_at), expiresAt: try date(record.expires_at),
                                     contextLength: record.context_length)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 256 &&
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        guard value.utf8.count <= 80 else { throw OllamaWidgetError.response }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = format.date(from: value)
        if date == nil { format.formatOptions = [.withInternetDateTime]; date = format.date(from: value) }
        guard let date, date.timeIntervalSince1970.isFinite,
              abs(date.timeIntervalSince1970) <= 253_402_300_799 else { throw OllamaWidgetError.response }
        return date
    }
}

/// Each explicit read owns an ephemeral session; no cookies, stored authentication or redirects.
final class OllamaWidgetHTTP: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    static func load(_ endpoint: OllamaWidgetEndpoint) async throws -> OllamaWidgetReport {
        let delegate = OllamaWidgetHTTP()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            async let tags = read(try endpoint.api("tags"), session: session)
            async let ps = read(try endpoint.api("ps"), session: session)
            async let version = read(try endpoint.api("version"), session: session)
            let data = try await (tags, ps, version)
            try Task.checkCancellation()
            return try OllamaWidgetReport(endpoint: endpoint.url.absoluteString, version: OllamaWidgetParser.version(data.2),
                                          installed: OllamaWidgetParser.models(data.0), running: OllamaWidgetParser.models(data.1), fetchedAt: .now)
        } catch is CancellationError { throw CancellationError() }
        catch let error as OllamaWidgetError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw OllamaWidgetError.unavailable }
    }
    private static func read(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OllamaWidgetError.response }
        guard (200...299).contains(http.statusCode) else { throw OllamaWidgetError.http(http.statusCode) }
        if response.expectedContentLength > Int64(OllamaWidgetParser.maximumBytes) { throw OllamaWidgetError.tooLarge }
        var data = Data(); data.reserveCapacity(16_384)
        for try await byte in stream {
            guard data.count < OllamaWidgetParser.maximumBytes else { throw OllamaWidgetError.tooLarge }
            if data.count % 1024 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        try OllamaWidgetParser.validateSize(data.count)
        return data
    }
}
