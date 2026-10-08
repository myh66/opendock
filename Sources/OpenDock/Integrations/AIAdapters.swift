import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case codex, claude, grok, cursor, gemini, copilot, antigravity
    var id: String { rawValue }
    var title: String { switch self { case .codex: return "Codex"; case .claude: return "Claude"; case .grok: return "Grok"; case .cursor: return "Cursor"; case .gemini: return "Gemini CLI"; case .copilot: return "GitHub Copilot"; case .antigravity: return "Antigravity CLI" } }
    var supportsActivity: Bool { [.codex, .claude, .grok, .cursor].contains(self) }
    var instructions: String {
        switch self {
        case .codex: return "选择 Codex sessions 文件夹读取数值记录；选择已登录的 codex 可执行文件，可通过官方 app-server 查询账号额度，不创建模型任务。"
        case .claude: return "选择 Claude projects 读取本地用量；连接状态栏保留旧命令并仅接收 rate_limits 数值。可明确选择 Claude Desktop Cookies，状态栏缺失或超过五分钟时查询桌面账号额度；后台不触发新授权，版本不提供额度则保持上次数据。"
        case .grok: return "选择 Grok sessions 读取数值 usage.json；日期按文件修改日归属，属于本地估算。明确允许后只读已登录 auth.json，通过官方 CLI billing 接口查询额度；不刷新凭据。"
        case .cursor: return "团队可连接官方 Admin API；个人账号可明确允许只读 Cursor state.vscdb 登录令牌，查询仪表盘的额度与活动接口（非稳定公开 API）。供应商报告费用不等于账单。"
        case .gemini: return "明确允许后只读 Gemini CLI Google 登录的 oauth_creds.json，通过官方 CLI retrieveUserQuota 查询真实额度。不会刷新过期凭据；请先在 Gemini CLI 完成登录。"
        case .copilot: return "选择已登录的 Copilot CLI，通过公开 SDK account.getQuota 查询；不创建会话或启动模型任务。已登录 gh 可作为客户端接口兼容回退。无限或未返回额度不会生成百分比。"
        case .antigravity: return "连接状态栏后重开 agy 并运行 /usage。接收官方 quota.remaining_fraction / reset_time；无活动历史。断开仅在命令仍匹配时恢复旧设置。"
        }
    }
}
struct AIAllowance: Codable, Identifiable, Equatable {
    var id: String
    var usedPercent: Double
    var resetsAt: Date?
    var windowMinutes: Int?
    var title: String { if let windowMinutes { return windowMinutes >= 1440 ? "\(windowMinutes / 1440) 天" : "\(windowMinutes / 60) 小时" }; return id }
}
struct AIActivityRecord: Codable, Identifiable, Equatable {
    var id: String
    var session: String
    var date: Date
    var input: Int64 = 0
    var output: Int64 = 0
    var cached: Int64 = 0
    var tools: Int64 = 0
    var requests: Double = 0
    var costUSD: Double? = nil
    var estimated: Bool = false
    var tokenCoverage: String? = nil
    var requestsReported: Bool? = nil
    var tokens: Int64 { IntegrationNumber.saturatedSum([input, output]) }
}
struct AIReport: Codable, Equatable {
    var provider: AIProvider
    var allowances: [AIAllowance] = []
    var activity: [AIActivityRecord] = []
    var updatedAt: Date
    var note: String
    var reportedRequests: Double? = nil
    var reportedUnit: String? = nil
}
struct AIConnection: Codable {
    var folder: String? = nil
    var executable: String? = nil
    var importedReport: AIReport? = nil
    var memberEmail: String? = nil
    var username: String? = nil
    var authFile: String? = nil
    var quotaProject: String? = nil
    var existingLogin: Bool? = nil
    var copilotExecutable: String? = nil
}

enum AIAdapters {
    static func connection(_ provider: AIProvider) -> AIConnection { IntegrationDisk.read(AIConnection.self, key: "ai-connection-" + provider.rawValue) ?? AIConnection() }
    static func cache(_ provider: AIProvider) -> AIReport? { IntegrationDisk.read(AIReport.self, key: "ai-cache-" + provider.rawValue) }
    static func saveConnection(_ connection: AIConnection, provider: AIProvider) throws { try IntegrationDisk.write(connection, key: "ai-connection-" + provider.rawValue) }
    static func load(_ provider: AIProvider, explicit: Bool) async throws -> AIReport {
        let connection = connection(provider)
        var report = connection.importedReport ?? cache(provider) ?? AIReport(provider: provider, updatedAt: .now, note: provider.instructions)
        report.note = report.note.components(separatedBy: " 上次连接查询失败").first ?? report.note
        var failures: [String] = []
        func failed(_ error: Error) { failures.append((error as? IntegrationError)?.errorDescription ?? "连接读取未完成，请确认所选文件、工具登录状态与权限。") }
        if let folder = connection.folder, [.codex, .claude, .grok].contains(provider) {
            do {
            let local = try await Task.detached(priority: .utility) { try scan(folder: URL(fileURLWithPath: folder), provider: provider) }.value
            report.activity = local.activity
            if !local.allowances.isEmpty, local.updatedAt >= report.updatedAt { report.allowances = local.allowances; report.updatedAt = local.updatedAt }
            report.note = local.note
            } catch { failed(error) }
        }
        if provider == .codex, let executable = connection.executable {
            do {
            let object = try await CodexQuotaCommand.read(executable: executable)
            let windows = codexAllowances(object)
            guard !windows.isEmpty else { throw IntegrationError.invalid("当前 Codex 登录未提供订阅额度。API-key 登录或旧版本可能不支持 account/rateLimits/read。") }
            report.allowances = windows; report.updatedAt = .now
            report.note = "官方 Codex app-server 账号额度；活动为这台 Mac 的数值日志，两者范围不同。"
            } catch { failed(error) }
        }
        let bridge = IntegrationDisk.read(AIReport.self, key: "ai-bridge-" + provider.rawValue)
        if [.claude, .antigravity].contains(provider), let bridge {
            report.allowances = bridge.allowances; report.updatedAt = bridge.updatedAt
            report.note += " 状态栏报告；重置时间经过不会自动假设额度满额。"
        }
        let bridgeIsFresh = bridge.map { !$0.allowances.isEmpty && (0...300).contains(Date.now.timeIntervalSince($0.updatedAt)) } ?? false
        if provider == .claude, !bridgeIsFresh, ClaudeDesktopUsage.selectedCookieDatabase != nil {
            do {
                let desktop = try await ClaudeDesktopUsage.shared.refresh(explicit: explicit)
                report.allowances = desktop.allowances; report.updatedAt = desktop.updatedAt
                report.note = desktop.note + " 活动仍为本机 projects 数值记录，与桌面账号额度范围分别计算。"
            } catch { failed(error) }
        }
        do { if provider == .cursor, let secrets = try IntegrationKeychain.read(account: "ai-cursor", allowPrompt: explicit), let key = secrets["key"] {
            report = try await cursor(key: key, email: connection.memberEmail)
        } } catch { failed(error) }
        do { if provider == .copilot, let secrets = try IntegrationKeychain.read(account: "ai-copilot", allowPrompt: explicit), let key = secrets["key"], let username = connection.username {
            report = try await copilot(key: key, username: username)
        } } catch { failed(error) }
        if connection.existingLogin == true {
            do {
            switch provider {
            case .gemini: report = try await geminiExistingLogin(connection)
            case .grok:
                let live = try await grokExistingLogin(connection)
                report.allowances = live.allowances; report.updatedAt = live.updatedAt; report.note = live.note + " 活动日期为本地文件修改日估算。"
            case .copilot: report = try await copilotExistingLogin(connection)
            case .cursor: report = try await cursorExistingLogin(connection)
            default: break
            }
            } catch { failed(error) }
        }
        guard !report.allowances.isEmpty || !report.activity.isEmpty || report.reportedRequests != nil else { throw IntegrationError.invalid(failures.first ?? IntegrationError.noData.localizedDescription) }
        if !failures.isEmpty { report.note += " 上次连接查询失败，已保留成功读取的本地活动与此前额度；额度时间未更新。" + failures.joined(separator: " ") }
        try IntegrationDisk.write(report, key: "ai-cache-" + provider.rawValue)
        return report
    }

    static func codexAllowances(_ object: [String: Any]) -> [AIAllowance] {
        let root = object["result"] as? [String: Any] ?? object
        var snapshots: [(String, [String: Any])] = []
        if let all = root["rateLimitsByLimitId"] as? [String: [String: Any]] { snapshots = all.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 } }
        else if let snapshot = root["rateLimits"] as? [String: Any] ?? root["rate_limits"] as? [String: Any] { snapshots = [(snapshot["limitId"] as? String ?? snapshot["limit_id"] as? String ?? "codex", snapshot)] }
        else if root["primary"] != nil { snapshots = [("codex", root)] }
        var windows: [AIAllowance] = []
        for (bucket, snapshot) in snapshots {
            for key in ["primary", "secondary"] {
                guard let window = snapshot[key] as? [String: Any], let used = IntegrationNumber.finite(window["usedPercent"] ?? window["used_percent"]), (0...100).contains(used) else { continue }
                let minutes = IntegrationNumber.finite(window["windowDurationMins"] ?? window["window_minutes"])
                windows.append(AIAllowance(id: bucket + "." + key, usedPercent: used, resetsAt: IntegrationNumber.date(window["resetsAt"] ?? window["resets_at"]), windowMinutes: minutes.flatMap { $0 > 0 && $0 <= 525600 ? Int($0) : nil }))
            }
        }
        return windows
    }
    static func statusReport(_ object: [String: Any], provider: AIProvider, now: Date = .now) -> AIReport {
        var windows: [AIAllowance] = []
        if provider == .claude, let limits = object["rate_limits"] as? [String: [String: Any]] {
            for key in ["five_hour", "seven_day", "spend_limit"] {
                guard let row = limits[key], let used = IntegrationNumber.finite(row["used_percentage"]), (0...100).contains(used) else { continue }
                windows.append(AIAllowance(id: key, usedPercent: used, resetsAt: IntegrationNumber.date(row["resets_at"]), windowMinutes: key == "five_hour" ? 300 : key == "seven_day" ? 10080 : nil))
            }
        }
        if provider == .antigravity, let quotas = object["quota"] as? [String: [String: Any]] {
            for (key, row) in quotas.sorted(by: { $0.key < $1.key }) {
                guard key.count <= 100, let remaining = IntegrationNumber.finite(row["remaining_fraction"]), (0...1).contains(remaining) else { continue }
                windows.append(AIAllowance(id: key, usedPercent: (1 - remaining) * 100, resetsAt: IntegrationNumber.date(row["reset_time"]), windowMinutes: nil))
            }
        }
        return AIReport(provider: provider, allowances: windows, updatedAt: now, note: "官方 status-line 数值报告，不保留工作区、邮箱、模型对话或 transcript 内容。")
    }

    /// Explicit report contract. Unknown schemas are rejected instead of guessed.
    static func imported(_ data: Data, provider: AIProvider) throws -> AIReport {
        guard data.count <= 16_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["version"] as? Int == 1,
              object["provider"] as? String == provider.rawValue, let updated = IntegrationNumber.date(object["updated_at"]) else { throw IntegrationError.schema }
        var windows: [AIAllowance] = []
        for row in object["limits"] as? [[String: Any]] ?? [] {
            guard let id = row["id"] as? String, id.count <= 100, let used = IntegrationNumber.finite(row["used_percent"]), (0...100).contains(used) else { throw IntegrationError.schema }
            windows.append(AIAllowance(id: id, usedPercent: used, resetsAt: IntegrationNumber.date(row["resets_at"]), windowMinutes: nil))
        }
        var activity: [AIActivityRecord] = []
        if provider.supportsActivity {
            for row in object["activity"] as? [[String: Any]] ?? [] {
                guard let id = row["id"] as? String, let date = IntegrationNumber.date(row["timestamp"]) else { throw IntegrationError.schema }
                activity.append(AIActivityRecord(id: IntegrationNumber.hash(id), session: IntegrationNumber.hash(row["session"] as? String ?? id), date: date,
                                                 input: IntegrationNumber.count(row["input_tokens"]), output: IntegrationNumber.count(row["output_tokens"]), cached: IntegrationNumber.count(row["cached_tokens"]),
                                                 tools: IntegrationNumber.count(row["tool_calls"]), requests: IntegrationNumber.quantity(row["requests"]) ?? 0, costUSD: IntegrationNumber.quantity(row["cost_usd"]), estimated: provider == .grok))
            }
        }
        guard !windows.isEmpty || !activity.isEmpty else { throw IntegrationError.noData }
        return AIReport(provider: provider, allowances: windows, activity: activity, updatedAt: updated, note: provider == .grok ? "用户导入的 Grok 本地估算；不等于精确每日消耗。" : "用户主动导入的供应商数值报告。请确保来源真实，导入不会查询账户或猜测配额。")
    }

    static func scan(folder: URL, provider: AIProvider) throws -> AIReport {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw IntegrationError.invalid("无法读取已选择的日志文件夹。") }
        var reports: [AIReport] = [], visited = 0
        for case let url as URL in enumerator {
            guard visited < 10_000 else { throw IntegrationError.incomplete }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 64_000_000, !url.lastPathComponent.lowercased().contains("credential"), !url.lastPathComponent.lowercased().contains("auth") else { continue }
            guard provider == .grok ? url.pathExtension == "json" : url.pathExtension == "jsonl" else { continue }
            visited += 1
            let data = try Data(contentsOf: url)
            let session = IntegrationNumber.hash(url.path)
            if provider == .grok {
                // Official Grok Build persisted usage ledger, not transcripts.
                guard url.lastPathComponent == "usage.json", let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let summary = object["session"] as? [String: Any],
                      IntegrationNumber.finite(summary["inputTokens"]) != nil, IntegrationNumber.finite(summary["outputTokens"]) != nil else { continue }
                let stamp = values.contentModificationDate ?? .now
                reports.append(AIReport(provider: provider, activity: [AIActivityRecord(id: session, session: session, date: stamp, input: IntegrationNumber.count(summary["inputTokens"]), output: IntegrationNumber.count(summary["outputTokens"]), cached: IntegrationNumber.count(summary["cachedReadTokens"]) + IntegrationNumber.count(summary["cacheCreationTokens"]), requests: IntegrationNumber.finite(summary["modelCalls"]) ?? 0, estimated: true)], updatedAt: stamp, note: "Grok 本地 usage.json 数值，按文件最后修改日归属；不等于精确每日消耗。未知格式不作推算。"))
            } else { reports.append(parseJSONL(data, provider: provider, session: session)) }
        }
        var report = AIReport(provider: provider, updatedAt: .distantPast, note: provider == .grok ? "Grok summary 本地估算；按文件修改日归属，未知 schema 不作推算。" : "本机数值日志；不包含全部账号活动，未留存 prompts、messages 或 tool arguments。")
        var unique: [String: AIActivityRecord] = [:]
        for parsed in reports {
            if parsed.updatedAt > report.updatedAt, !parsed.allowances.isEmpty { report.allowances = parsed.allowances; report.updatedAt = parsed.updatedAt }
            for event in parsed.activity { unique[event.id] = event }
        }
        report.activity = unique.values.sorted { $0.date < $1.date }
        if report.updatedAt == .distantPast { report.updatedAt = .now }
        return report
    }

    static func parseJSONL(_ data: Data, provider: AIProvider, session: String) -> AIReport {
        var report = AIReport(provider: provider, updatedAt: .distantPast, note: "本地数值记录")
        var previous: [Int64]?, records: [String: AIActivityRecord] = [:]
        for line in data.split(separator: 10) {
            guard line.count <= 8_000_000, let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let date = IntegrationNumber.date(object["timestamp"]) else { continue }
            if provider == .codex, object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count" {
                if let limits = payload["rate_limits"] as? [String: Any] {
                    let windows = codexAllowances(limits)
                    if !windows.isEmpty, date > report.updatedAt { report.allowances = windows; report.updatedAt = date }
                }
                guard let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] else { continue }
                let values = [IntegrationNumber.count(total["input_tokens"]), IntegrationNumber.count(total["output_tokens"]), IntegrationNumber.count(total["cached_input_tokens"])]
                let delta: [Int64]
                if let old = previous { delta = zip(values, old).map { max(0, $0 - $1) } }
                else if let last = info["last_token_usage"] as? [String: Any] { delta = [IntegrationNumber.count(last["input_tokens"]), IntegrationNumber.count(last["output_tokens"]), IntegrationNumber.count(last["cached_input_tokens"])] }
                else { delta = values }
                previous = values
                guard delta.contains(where: { $0 > 0 }) else { continue }
                let id = IntegrationNumber.hash(session + "-" + values.map(String.init).joined(separator: ":"))
                records[id] = AIActivityRecord(id: id, session: session, date: date, input: delta[0], output: delta[1], cached: delta[2])
            }
            if provider == .codex, object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any], ["function_call", "custom_tool_call"].contains(payload["type"] as? String ?? ""), let call = payload["call_id"] as? String {
                let id = IntegrationNumber.hash(session + "tool" + call); records[id] = AIActivityRecord(id: id, session: session, date: date, tools: 1)
            }
            if provider == .claude, object["type"] as? String == "assistant", let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any], let messageID = message["id"] as? String {
                let cached = IntegrationNumber.count(usage["cache_read_input_tokens"]) + IntegrationNumber.count(usage["cache_creation_input_tokens"])
                let input = IntegrationNumber.count(usage["input_tokens"]) + cached
                let tools = (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_use" }.count
                let id = IntegrationNumber.hash(messageID)
                let current = AIActivityRecord(id: id, session: session, date: date, input: input, output: IntegrationNumber.count(usage["output_tokens"]), cached: cached, tools: Int64(tools), requests: 1)
                if let old = records[id], old.tokens > current.tokens { continue }
                records[id] = current
            }
        }
        report.activity = records.values.sorted { $0.date < $1.date }
        return report
    }

    static func cursor(key: String, email: String?) async throws -> AIReport {
        let interval = IntegrationPeriod.l30.interval()
        var events: [AIActivityRecord] = []
        for page in 1...100 {
            var body: [String: Any] = ["startDate": Int(interval.start.timeIntervalSince1970 * 1000), "endDate": Int(interval.end.timeIntervalSince1970 * 1000), "page": page, "pageSize": 100]
            if let email, !email.isEmpty { body["email"] = email }
            let object = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://api.cursor.com/teams/filtered-usage-events"), headers: ["Authorization": "Basic " + Data((key + ":").utf8).base64EncodedString()], body: body)
            guard let rows = object["usageEvents"] as? [[String: Any]] else { throw IntegrationError.schema }
            for row in rows {
                guard let date = IntegrationNumber.date(row["timestamp"]), let id = row["id"] as? String ?? row["requestId"] as? String else { continue }
                let usage = row["tokenUsage"] as? [String: Any] ?? [:]
                let cached = IntegrationNumber.count(usage["cacheReadTokens"]) + IntegrationNumber.count(usage["cacheWriteTokens"])
                let input = IntegrationNumber.count(usage["inputTokens"]) + cached
                events.append(AIActivityRecord(id: IntegrationNumber.hash(id), session: "", date: date, input: input, output: IntegrationNumber.count(usage["outputTokens"]), cached: cached, requests: IntegrationNumber.finite(row["requestsCosts"]) ?? 0, costUSD: IntegrationNumber.finite(usage["totalCents"]).map { $0 / 100 }))
            }
            if object["hasNextPage"] as? Bool != true, rows.count < 100 { break }
            if let total = IntegrationNumber.finite(object["totalUsageEventsCount"]), Double(page * 100) >= total { break }
            if page == 100 { throw IntegrationError.incomplete }
        }
        return AIReport(provider: .cursor, activity: events, updatedAt: .now, note: "Cursor 官方 Admin API，团队或指定成员，近 30 天；请求数为 requestsCosts，API token 费用为供应商报告值，不等于最终账单。缺失 token/cost 字段不是零。个人额度接口尚未接入。")
    }
    static func copilot(key: String, username: String) async throws -> AIReport {
        guard username.range(of: #"^[A-Za-z0-9-]{1,39}$"#, options: .regularExpression) != nil else { throw IntegrationError.invalid("请输入有效 GitHub 用户名。") }
        let object = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://api.github.com/users/\(username)/settings/billing/premium_request/usage"), headers: ["Authorization": "Bearer " + key, "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2026-03-10"])
        guard let rows = object["usageItems"] as? [[String: Any]] else { throw IntegrationError.schema }
        let requests = min(9_000_000_000_000_000, rows.filter { ($0["product"] as? String ?? "").lowercased().contains("copilot") }.reduce(0.0) { $0 + (IntegrationNumber.quantity($1["grossQuantity"]) ?? 0) })
        return AIReport(provider: .copilot, updatedAt: .now, note: "GitHub 官方个人计费 premium requests（本月）。接口不提供包含额度或重置配额，未计算百分比；组织支付账号不在此范围。", reportedRequests: requests)
    }
}
