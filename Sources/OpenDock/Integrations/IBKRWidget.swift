import AppKit
import CoreFoundation
import SwiftUI

struct IBKRAccount: Identifiable, Equatable {
    let id: String
    let name: String
    let currency: String
    var maskedID: String { "•••" + id.suffix(4) }
}
struct IBKRLedger: Equatable {
    let currency: String
    let netValue: Double?
    let cash: Double?
    let unrealized: Double?
}
struct IBKRPosition: Identifiable, Equatable {
    let id: String
    let name: String
    let quantity: Double?
    let marketValue: Double?
    let currency: String
}
enum IBKRReadError: LocalizedError {
    case invalidAddress, invalidAccount, malformed, missingBase, oversized, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请填写本机 HTTPS Client Portal Gateway 地址，例如 https://localhost:5000/v1/api。"
        case .invalidAccount: return "所选账户不在网关返回的可读账户中，请重新选择。"
        case .malformed: return "网关未返回有效的账户 JSON。"
        case .missingBase: return "网关未返回 BASE 汇总，暂时无法显示账户总资产。"
        case .oversized: return "网关响应超出读取上限。"
        case .http(let code): return code == 401 || code == 403 ? "请先在 Client Portal Gateway 中完成登录，再刷新。" : "网关返回 HTTP \(code)，请检查本机会话。"
        }
    }
}

/// Only the documented portfolio GET endpoints are exposed. No trading or authentication actions.
enum IBKRReader {
    /// Incomplete ordinary addresses may be saved, but credentials and URL
    /// parameters stay in the editor's memory even when connection is rejected.
    static func gatewayDraftCanPersist(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("@"), !text.contains("?"), !text.contains("#") else { return false }
        guard let parts = URLComponents(string: text) else {
            // A malformed URL with an authority/path cannot be checked safely.
            return !text.contains("/")
        }
        return parts.user == nil && parts.password == nil && parts.query == nil && parts.fragment == nil
    }
    static func configurationBySavingGatewayDraft(_ draft: String, in configuration: [String: String]) -> [String: String] {
        var saved = configuration
        if let previous = saved["ibkrGateway"], !gatewayDraftCanPersist(previous) { saved.removeValue(forKey: "ibkrGateway") }
        if gatewayDraftCanPersist(draft) { saved["ibkrGateway"] = draft }
        return saved
    }
    static func gateway(_ text: String) throws -> URL {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw IBKRReadError.invalidAddress }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty || path == "v1/api" else { throw IBKRReadError.invalidAddress }
        parts.path = "/v1/api"
        guard let url = parts.url else { throw IBKRReadError.invalidAddress }; return url
    }
    static func validAccount(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }
    }
    static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }; result = value.doubleValue
        } else if let value = value as? String { result = Double(value) } else { return nil }
        guard let result, result.isFinite else { return nil }; return result
    }
    private static func object(_ data: Data) throws -> Any {
        guard data.count <= 2_000_000 else { throw IBKRReadError.oversized }
        do { return try JSONSerialization.jsonObject(with: data) } catch { throw IBKRReadError.malformed }
    }
    static func accounts(_ data: Data) throws -> [IBKRAccount] {
        guard let rows = try object(data) as? [[String: Any]], rows.count <= 500 else { throw IBKRReadError.malformed }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = (row["accountId"] ?? row["id"]) as? String, validAccount(id), seen.insert(id).inserted else { return nil }
            let alias = (row["accountAlias"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return IBKRAccount(id: id, name: alias ?? "IBKR 账户", currency: row["currency"] as? String ?? "")
        }
    }
    static func ledger(_ data: Data, currency: String) throws -> IBKRLedger {
        guard let rows = try object(data) as? [String: Any] else { throw IBKRReadError.malformed }
        // BASE is already aggregated by IBKR. Never add currency buckets together.
        guard let base = rows["BASE"] as? [String: Any] else { throw IBKRReadError.missingBase }
        let code = base["currency"] as? String ?? ""
        return IBKRLedger(currency: code == "BASE" || code.isEmpty ? currency : code,
                          netValue: number(base["netliquidationvalue"]), cash: number(base["cashbalance"]), unrealized: number(base["unrealizedpnl"]))
    }
    static func positions(_ data: Data) throws -> [IBKRPosition] {
        guard let rows = try object(data) as? [[String: Any]], rows.count <= 500 else { throw IBKRReadError.malformed }
        return rows.enumerated().map { index, row in
            let conid = (row["conid"] as? NSNumber)?.stringValue ?? String(index)
            let model = row["model"] as? String ?? ""
            return IBKRPosition(id: conid + ":" + model, name: row["contractDesc"] as? String ?? row["ticker"] as? String ?? "合约 " + conid,
                                quantity: number(row["position"]), marketValue: number(row["mktValue"]), currency: row["currency"] as? String ?? "")
        }
    }
}

private final class IBKRRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
final class IBKRReadClient {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 12
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: IBKRRedirectGuard(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func get(base: URL, path: String) async throws -> Data {
        let url = base.appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw IBKRReadError.malformed }
        guard (200...299).contains(http.statusCode) else { throw IBKRReadError.http(http.statusCode) }
        guard response.expectedContentLength <= 2_000_000 else { throw IBKRReadError.oversized }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation(); guard data.count < 2_000_000 else { throw IBKRReadError.oversized }; data.append(byte)
        }
        return data
    }
}

@MainActor private final class IBKRWidgetRuntime: ObservableObject {
    @Published var accounts: [IBKRAccount] = []
    @Published var accountID = ""
    @Published var ledger: IBKRLedger?
    @Published var positions: [IBKRPosition] = []
    @Published var warning: String?
    @Published var error: String?
    @Published var fetched: Date?
    @Published var busy = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func reset() {
        task?.cancel(); generation = UUID(); busy = false
        accounts = []; accountID = ""; ledger = nil; positions = []; warning = nil; error = nil; fetched = nil
    }
    func cancel() {
        if busy && ledger != nil { warning = "读取已取消，显示已返回的数据；持仓列表可能不完整。" }
        task?.cancel(); generation = UUID(); busy = false
    }
    func refresh(address: String, selectedID: String, selected: @escaping (String) -> Void) {
        cancel(); let revision = generation; busy = true; error = nil; warning = nil
        task = Task {
            defer { if generation == revision { busy = false } }
            do {
                let base = try IBKRReader.gateway(address), client = IBKRReadClient()
                let available = try IBKRReader.accounts(await client.get(base: base, path: "portfolio/accounts"))
                try Task.checkCancellation(); guard generation == revision else { return }
                accounts = available
                guard let account = selectedID.isEmpty ? available.first : available.first(where: { $0.id == selectedID }) else { throw IBKRReadError.invalidAccount }
                if accountID != account.id { ledger = nil; positions = []; fetched = nil }
                accountID = account.id; selected(account.id)
                let balance = try IBKRReader.ledger(await client.get(base: base, path: "portfolio/\(account.id)/ledger"), currency: account.currency)
                try Task.checkCancellation(); guard generation == revision else { return }
                ledger = balance; fetched = .now; positions = []
                var collected: [IBKRPosition] = [], seen = Set<String>()
                do {
                    for page in 0..<10 {
                        let rows = try IBKRReader.positions(await client.get(base: base, path: "portfolio/\(account.id)/positions/\(page)"))
                        try Task.checkCancellation(); guard generation == revision else { return }
                        if rows.isEmpty { break }
                        let fresh = rows.filter { seen.insert($0.id).inserted }
                        collected += fresh
                        positions = collected
                        if fresh.isEmpty { warning = "网关重复返回同一页；持仓列表可能不完整。"; break }
                        if page == 9 { warning = "已读取前 10 页持仓；列表可能不完整。" }
                    }
                    positions = collected
                } catch {
                    if !Task.isCancelled && generation == revision { positions = collected; warning = "持仓仅部分返回，请重新刷新。" }
                }
            } catch {
                guard !Task.isCancelled, generation == revision else { return }
                if let issue = error as? URLError, [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .secureConnectionFailed].contains(issue.code) {
                    self.error = "网关证书未通过系统验证。请为网关配置受信任的本机 HTTPS 证书后连接。"
                } else { self.error = error.localizedDescription }
            }
        }
    }
}

struct IBKRWidgetTile: View {
    let item: DockItem
    var compact = false
    let onUpdate: (DockItem) -> Void
    @StateObject private var runtime = IBKRWidgetRuntime()
    @ObservedObject private var coordinator = WidgetPopoverCoordinator.shared
    @State private var presented = false
    @State private var address = "https://localhost:5000/v1/api"
    @State private var configuration: [String: String] = [:]
    private var hidden: Bool { configuration["ibkrHideAmounts"] != "false" }
    private var selectedID: String { configuration["ibkrAccountID"] ?? "" }
    var body: some View {
        Button { NSApp.activate(ignoringOtherApps: true); presented.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 21)).foregroundStyle(.red).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(runtime.ledger == nil ? "连接 IBKR" : hidden ? "资产 ••••" : amount(runtime.ledger?.netValue, currency: runtime.ledger?.currency ?? "")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(runtime.busy ? "读取账户…" : runtime.fetched == nil ? "本机网关 · 只读" : runtime.error != nil ? "上次读取 · 请刷新" : "\(runtime.positions.count) 项持仓 · 手动刷新").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 11).frame(width: compact ? 132 : 140, height: 58).dockGlass(cornerRadius: 14, tint: Color.red.opacity(0.07), interactive: true)
        }.buttonStyle(.plain).help("IBKR：只读账户余额与持仓")
            .popover(isPresented: $presented, arrowEdge: compact ? .leading : .bottom) { popover }
            .onAppear { configuration = item.configuration; address = configuration["ibkrGateway"] ?? "https://localhost:5000/v1/api" }
            .onChange(of: item.configuration) { updated in
                let previousID = configuration["ibkrAccountID"] ?? ""
                let previousGateway = configuration["ibkrGateway"] ?? "https://localhost:5000/v1/api"
                configuration = updated
                let value = updated["ibkrGateway"] ?? "https://localhost:5000/v1/api"
                // An unrelated saved option must not replace a sensitive,
                // deliberately unsaved address currently being edited.
                if previousGateway != value { address = value; runtime.reset() }
                else if previousID != (updated["ibkrAccountID"] ?? ""), runtime.accountID != (updated["ibkrAccountID"] ?? "") { runtime.reset() }
            }
            .onChange(of: presented) { open in
                if open { coordinator.activeID = item.id }
                else { runtime.cancel(); if coordinator.activeID == item.id { coordinator.activeID = nil } }
            }
            .onChange(of: coordinator.activeID) { if $0 != item.id { presented = false } }
            .onDisappear { runtime.cancel(); if coordinator.activeID == item.id { coordinator.activeID = nil } }
    }
    private var popover: some View {
        VStack(alignment: .leading, spacing: 14) {
            WidgetPopoverHeader(title: "IBKR", symbol: "chart.bar.xaxis", tint: .red, subtitle: "Client Portal Gateway · 只读", onClose: { presented = false }) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    connection
                    if let ledger = runtime.ledger { balances(ledger) }
                    if let warning = runtime.warning { Label(warning, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                    if !runtime.positions.isEmpty { holdings }
                    if let error = runtime.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    Text("数据仅保留在当前组件内存，关闭应用后需重新读取。账户选择随布局保存；不存储登录凭据。").font(.caption2).foregroundStyle(.secondary)
                }.padding(14).dockCard(cornerRadius: 16)
            }.frame(maxHeight: runtime.ledger == nil ? (runtime.error != nil || !IBKRReader.gatewayDraftCanPersist(address) ? 330 : 280) : 440)
        }.padding(18).frame(width: 390).dockCard(cornerRadius: 22).textFieldStyle(.roundedBorder)
            .onExitCommand { presented = false }
            .background { Button("关闭 IBKR") { presented = false }.keyboardShortcut("w", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true) }
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本机网关地址").font(.caption.weight(.medium))
            TextField("https://localhost:5000/v1/api", text: $address).onChange(of: address) { value in saveGatewayDraft(value); runtime.reset() }
            if !IBKRReader.gatewayDraftCanPersist(address) {
                Label("地址含认证信息、参数或无法安全解析，仅保留在当前内存中，未保存到布局。请移除后再连接。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("先运行并登录 IBKR Client Portal Gateway，使用受系统信任的 HTTPS 证书。TWS / IB Gateway 的 TCP 端口不适用。").font(.caption).foregroundStyle(.secondary)
            if !runtime.accounts.isEmpty {
                Picker("账户", selection: Binding(get: { selectedID }, set: { value in set("ibkrAccountID", value); runtime.cancel(); runtime.accountID = value; runtime.ledger = nil; runtime.positions = []; runtime.fetched = nil; refresh() })) {
                    ForEach(runtime.accounts) { account in Text(account.name + " · " + account.maskedID).tag(account.id) }
                }
            }
            HStack {
                Button(runtime.busy ? "取消读取" : "连接并刷新") { if runtime.busy { runtime.cancel() } else { refresh() } }.buttonStyle(DockGlassButtonStyle(prominent: true)).disabled(!runtime.busy && (try? IBKRReader.gateway(address)) == nil)
                if runtime.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            Toggle("隐藏金额与持仓份额", isOn: Binding(get: { hidden }, set: { set("ibkrHideAmounts", String($0)) })).font(.caption)
            Link("网关设置说明 ↗", destination: URL(string: "https://www.interactivebrokers.com/docs/web-api/v1/endpoints/introduction")!).font(.caption)
        }
    }
    private func balances(_ ledger: IBKRLedger) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            metric("净资产", value: ledger.netValue, currency: ledger.currency)
            metric("现金余额", value: ledger.cash, currency: ledger.currency)
            metric("未实现盈亏", value: ledger.unrealized, currency: ledger.currency)
            if let fetched = runtime.fetched { Text("账本读取于 " + fetched.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private var holdings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("持仓 · \(runtime.positions.count) 项").font(.headline)
            ForEach(runtime.positions) { position in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(position.name).font(.caption.weight(.medium)).lineLimit(2); Text(hidden ? "数量 ••••" : "数量 " + (position.quantity.map { $0.formatted() } ?? "—")).font(.caption2).foregroundStyle(.secondary) }
                    Spacer(); Text(hidden ? "••••" : amount(position.marketValue, currency: position.currency)).font(.caption).monospacedDigit()
                }
                Divider()
            }
        }
    }
    private func metric(_ title: String, value: Double?, currency: String) -> some View {
        HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Text(hidden ? "••••" : amount(value, currency: currency)).font(.callout.weight(.semibold)).monospacedDigit() }
    }
    private func amount(_ value: Double?, currency: String) -> String {
        guard let value else { return "—" }; return (currency.isEmpty ? "" : currency + " ") + value.formatted(.number.precision(.fractionLength(2)))
    }
    private func saveGatewayDraft(_ value: String) {
        publish(IBKRReader.configurationBySavingGatewayDraft(value, in: configuration))
    }
    private func set(_ key: String, _ value: String) {
        var saved = IBKRReader.configurationBySavingGatewayDraft(address, in: configuration)
        saved[key] = value; publish(saved)
    }
    private func publish(_ saved: [String: String]) {
        guard configuration != saved else { return }
        configuration = saved; var updated = item; updated.configuration = saved; onUpdate(updated)
    }
    private func refresh() { runtime.refresh(address: address, selectedID: selectedID) { value in set("ibkrAccountID", value) } }
}
