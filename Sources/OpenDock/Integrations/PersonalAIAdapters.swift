import Foundation
import Darwin

/// User-selected existing login files are read only after persistent opt-in.
/// Tokens stay in memory and are never copied into reports or exported settings.
enum IntegrationLogin {
    static func json(path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw IntegrationError.invalid("已选择的登录文件无法读取或格式不受支持。请在供应商 CLI 中重新登录。") }
        return object
    }
    static func jwt(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts[1].count < 100_000 else { return nil }
        var segment = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        segment += String(repeating: "=", count: (4 - segment.count % 4) % 4)
        guard let data = Data(base64Encoded: segment) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    static func validToken(_ token: String, expiry: Date?) throws {
        guard !token.isEmpty, token.utf8.count <= 100_000, !token.contains("\n"), !token.contains("\r") else { throw IntegrationError.schema }
        if let expiry, expiry <= .now { throw IntegrationError.invalid("登录已过期。OpenDock 不刷新或改写供应商凭据；请先在供应商 CLI / App 中重新登录。") }
    }
}

/// Fixed argv, no shell, no stderr retention; output and lifetime are bounded.
/// Used for gh API and a single SQLite auth key, never general DB/session dumps.
enum IntegrationReadCommand {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 20, maximum: Int = 2_000_000) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw IntegrationError.invalid("请选择有效的可执行文件。") }
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            let source = ProcessInfo.processInfo.environment
            var environment: [String: String] = [:]
            for key in ["PATH", "HOME", "TMPDIR", "XDG_CONFIG_HOME", "GH_CONFIG_DIR"] { environment[key] = source[key] }
            environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_BROWSER"] = "false"; environment["CI"] = "1"; environment["TERM"] = "dumb"
            process.environment = environment; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { throw IntegrationError.invalid("无法启动所选工具。") }
            let deadline = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { try? pipe.fileHandleForReading.close(); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; deadline.cancel() }
            var result = Data()
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 32_768)
                if chunk.isEmpty { break }
                guard result.count + chunk.count <= maximum else { process.terminate(); deadline.cancel(); throw IntegrationError.incomplete }
                result.append(chunk)
            }
            process.waitUntilExit(); deadline.cancel()
            guard process.terminationStatus == 0 else { throw IntegrationError.invalid("只读查询未完成；请确认工具已登录、账号有权限且网络可用。") }
            return result
        }.value
    }
}

extension AIAdapters {
    // Official Google CLI source: code_assist/{server,setup,types,oauth2}.ts.
    static func geminiExistingLogin(_ connection: AIConnection) async throws -> AIReport {
        guard connection.existingLogin == true, let file = connection.authFile else { throw IntegrationError.invalid("请选择 Gemini oauth_creds.json 并明确允许读取现有登录。") }
        let auth = try IntegrationLogin.json(path: file)
        guard let token = auth["access_token"] as? String, let expiry = IntegrationNumber.date(auth["expiry_date"]) else { throw IntegrationError.invalid("只支持 Gemini CLI 的 Google OAuth 登录文件；API-key、Vertex 或未知登录格式不支持此额度查询。") }
        try IntegrationLogin.validToken(token, expiry: expiry)
        let headers = ["Authorization": "Bearer " + token, "Accept": "application/json"]
        var body: [String: Any] = ["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"], "mode": "HEALTH_CHECK"]
        if let project = connection.quotaProject, !project.isEmpty {
            guard project.range(of: #"^[a-z][a-z0-9:-]{3,100}$"#, options: .regularExpression) != nil else { throw IntegrationError.invalid("请输入 Google 项目 ID，而非数字项目编号。") }
            body["cloudaicompanionProject"] = project
        }
        let loaded = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"), headers: headers, body: body)
        // Never call onboardUser, refresh OAuth, or trigger a model request.
        guard let project = loaded["cloudaicompanionProject"] as? String ?? connection.quotaProject, !project.isEmpty else { throw IntegrationError.invalid("当前 Google 登录未提供额度项目；请先在 Gemini CLI 完成设置，或填写已配置的 Google 项目 ID。") }
        let object = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"), headers: headers, body: ["project": project])
        return try geminiReport(object)
    }
    static func geminiReport(_ object: [String: Any]) throws -> AIReport {
        guard let buckets = object["buckets"] as? [[String: Any]] else { throw IntegrationError.schema }
        var windows: [AIAllowance] = []
        for (index, row) in buckets.enumerated() {
            guard let remaining = IntegrationNumber.finite(row["remainingFraction"]), (0...1).contains(remaining) else { continue }
            let model = row["modelId"] as? String ?? "quota-\(index + 1)"
            guard model.count <= 120 else { continue }
            windows.append(AIAllowance(id: model, usedPercent: (1 - remaining) * 100, resetsAt: IntegrationNumber.date(row["resetTime"]), windowMinutes: nil))
        }
        guard !windows.isEmpty else { throw IntegrationError.noData }
        return AIReport(provider: .gemini, allowances: windows, updatedAt: .now, note: "Google Gemini CLI 官方 retrieveUserQuota；逐模型账号额度，仅 Google 登录。凭据只读，不刷新过期登录，不生成模型请求。")
    }

    // Official xAI source: extensions/billing.rs, login/model.rs and credentials.
    static func grokExistingLogin(_ connection: AIConnection) async throws -> AIReport {
        guard connection.existingLogin == true, let file = connection.authFile else { throw IntegrationError.invalid("请选择 Grok auth.json 并明确允许读取现有登录。") }
        let object = try IntegrationLogin.json(path: file)
        let candidates: [[String: Any]] = object["key"] != nil ? [object] : object.values.compactMap { $0 as? [String: Any] }
        let firstParty = candidates.filter { row in
            guard row["auth_mode"] as? String != "api_key", let issuer = row["oidc_issuer"] as? String, let host = URL(string: issuer)?.host else { return false }
            return host == "auth.x.ai" || host == "accounts.x.ai"
        }
        guard firstParty.count == 1, let auth = firstParty.first, let token = auth["key"] as? String else { throw IntegrationError.invalid("需要单一 xAI 官方 OAuth 登录。多账号或自定义 SSO 登录请提供单账号登录文件；不会猜测选用哪个身份。") }
        let expiry = IntegrationNumber.date(auth["expires_at"]) ?? IntegrationNumber.date(auth["create_time"]).map { $0.addingTimeInterval(30 * 86400) }
        guard let expiry else { throw IntegrationError.schema }; try IntegrationLogin.validToken(token, expiry: expiry)
        var headers = ["Authorization": "Bearer " + token, "X-XAI-Token-Auth": "xai-grok-cli", "Accept": "application/json"]
        if let id = auth["user_id"] as? String, id.count < 200, !id.contains("\n"), !id.contains("\r") { headers["x-userid"] = id }
        let response = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://cli-chat-proxy.grok.com/v1/billing", query: [URLQueryItem(name: "format", value: "credits")]), headers: headers)
        return try grokReport(response)
    }
    static func grokReport(_ object: [String: Any]) throws -> AIReport {
        guard let config = object["config"] as? [String: Any] else { throw IntegrationError.schema }
        let period = config["currentPeriod"] as? [String: Any]
        let end = IntegrationNumber.date(period?["end"] ?? config["billingPeriodEnd"])
        var windows: [AIAllowance] = []
        if let used = IntegrationNumber.percent(config["creditUsagePercent"]) {
            windows.append(AIAllowance(id: "coding-credits", usedPercent: used, resetsAt: end, windowMinutes: nil))
        } else if let limit = IntegrationNumber.finite((config["monthlyLimit"] as? [String: Any])?["val"]), limit > 0,
                  let used = IntegrationNumber.quantity((config["used"] as? [String: Any])?["val"]), let percent = IntegrationNumber.percent(used / limit * 100) {
            windows.append(AIAllowance(id: "coding-credits", usedPercent: percent, resetsAt: end, windowMinutes: nil))
        }
        guard !windows.isEmpty else { throw IntegrationError.noData }
        return AIReport(provider: .grok, allowances: windows, updatedAt: .now, note: "xAI 官方 Grok CLI billing 包含 coding credits；不纳入购买余额或按需消费上限。超额进度按 100% 已用／0% 剩余显示。仅查询，不自动充值或刷新登录。")
    }

    // Copilot endpoint is shipped in Microsoft VS Code product.json, but has no
    // stable public REST contract. gh uses the user's existing github.com login.
    static func copilotExistingLogin(_ connection: AIConnection) async throws -> AIReport {
        guard connection.existingLogin == true else { throw IntegrationError.invalid("请明确允许查询现有 GitHub Copilot 登录。") }
        if let executable = connection.copilotExecutable {
            do { return try copilotSDKQuotaReport(await CopilotCLIQuotaCommand.read(executable: executable)) }
            catch { if connection.executable == nil { throw error } }
        }
        guard let executable = connection.executable else { throw IntegrationError.invalid("请选择已登录的 Copilot CLI 或 gh。") }
        let data = try await IntegrationReadCommand.run(executable: executable, arguments: ["api", "--hostname", "github.com", "/copilot_internal/user", "--header", "Accept: application/json", "--header", "X-GitHub-Api-Version: 2025-04-01"])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IntegrationError.schema }
        return try copilotQuotaReport(object)
    }
    static func copilotQuotaReport(_ object: [String: Any]) throws -> AIReport {
        guard let snapshots = object["quota_snapshots"] as? [String: [String: Any]] else { throw IntegrationError.schema }
        let reset = IntegrationNumber.date(object["quota_reset_date"])
        var windows: [AIAllowance] = [], credits: Double?
        for (key, row) in snapshots.sorted(by: { $0.key < $1.key }) {
            guard key.count <= 100 else { continue }
            if credits == nil, let used = IntegrationNumber.quantity(row["credits_used"]) { credits = used }
            guard row["unlimited"] as? Bool != true, let entitlement = IntegrationNumber.finite(row["entitlement"]), entitlement > 0 else { continue }
            let used: Double?
            if let remaining = IntegrationNumber.finite(row["percent_remaining"]), (0...100).contains(remaining) { used = 100 - remaining }
            else if let remaining = IntegrationNumber.finite(row["remaining"]), remaining >= 0 { used = max(0, entitlement - remaining) / entitlement * 100 }
            else { used = nil }
            if let used = IntegrationNumber.percent(used) { windows.append(AIAllowance(id: key, usedPercent: used, resetsAt: reset, windowMinutes: nil)) }
        }
        guard !windows.isEmpty || credits != nil else { throw IntegrationError.invalid("Copilot 当前计划仅返回无限额度或无可用数值上限。未生成百分比；客户端接口的响应也可能已改变。") }
        return AIReport(provider: .copilot, allowances: windows, updatedAt: .now, note: "GitHub Copilot 客户端接口（非稳定公开 REST 合约），使用已有 gh 登录。额度仅使用服务报告的 entitlement；无限及零占位额度不生成进度条。", reportedRequests: credits, reportedUnit: "AI credits")
    }
    static func copilotSDKQuotaReport(_ object: [String: Any]) throws -> AIReport {
        guard let snapshots = object["quotaSnapshots"] as? [String: [String: Any]] else { throw IntegrationError.schema }
        var windows: [AIAllowance] = []
        for (key, row) in snapshots.sorted(by: { $0.key < $1.key }) {
            guard key.count <= 100, row["isUnlimitedEntitlement"] as? Bool != true,
                  let entitlement = IntegrationNumber.finite(row["entitlementRequests"]), entitlement > 0 else { continue }
            let percent: Double?
            if let remaining = IntegrationNumber.finite(row["remainingPercentage"]), (0...100).contains(remaining) { percent = 100 - remaining }
            else if let used = IntegrationNumber.finite(row["usedRequests"]), used >= 0 { percent = used / entitlement * 100 }
            else { percent = nil }
            if let percent = IntegrationNumber.percent(percent) { windows.append(AIAllowance(id: key, usedPercent: percent, resetsAt: IntegrationNumber.date(row["resetDate"]), windowMinutes: nil)) }
        }
        guard !windows.isEmpty else { throw IntegrationError.invalid("Copilot SDK 未返回可用的有限额度；无限计划或缺失数值不生成进度条。") }
        return AIReport(provider: .copilot, allowances: windows, updatedAt: .now, note: "GitHub 官方 SDK account.getQuota（当前生成类型标为 experimental），读取 Copilot CLI 当前已登录账户；无会话、模型请求或自定义工具执行。")
    }

    static func cursorExistingLogin(_ connection: AIConnection) async throws -> AIReport {
        guard connection.existingLogin == true, let file = connection.authFile else { throw IntegrationError.invalid("请选择 Cursor state.vscdb 并明确允许只读现有登录。") }
        let token: String
        if file.hasSuffix(".vscdb") {
            let data = try await IntegrationReadCommand.run(executable: "/usr/bin/sqlite3", arguments: ["-readonly", file, "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1;"], maximum: 100_000)
            guard let string = String(data: data, encoding: .utf8) else { throw IntegrationError.schema }; token = string.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { let auth = try IntegrationLogin.json(path: file); token = auth["accessToken"] as? String ?? "" }
        guard let claims = IntegrationLogin.jwt(token), let user = claims["sub"] as? String, user.range(of: #"^[A-Za-z0-9_|:-]{1,200}$"#, options: .regularExpression) != nil,
              let expiry = IntegrationNumber.date(claims["exp"]) else { throw IntegrationError.schema }
        try IntegrationLogin.validToken(token, expiry: expiry)
        let cookie = (user + "::" + token).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let headers = ["Cookie": "WorkosCursorSessionToken=" + cookie, "Origin": "https://cursor.com", "Accept": "application/json"]
        let summary = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://cursor.com/api/usage-summary"), headers: headers)
        var report = try cursorQuotaReport(summary)
        do {
        let interval = IntegrationPeriod.l30.interval()
        var rows: [[String: Any]] = [], expected: Int?, completed = false
        for page in 1...100 {
            let body: [String: Any] = ["page": page, "pageSize": 100, "startDate": String(Int(interval.start.timeIntervalSince1970 * 1000)), "endDate": String(Int(interval.end.timeIntervalSince1970 * 1000))]
            let object = try await IntegrationHTTP.shared.json(IntegrationHTTP.url("https://cursor.com/api/dashboard/get-filtered-usage-events"), headers: headers, body: body)
            if object.isEmpty { if expected == nil { expected = 0 }; completed = true; break }
            guard let events = object["usageEventsDisplay"] as? [[String: Any]], let count = IntegrationNumber.finite(object["totalUsageEventsCount"]), count >= 0, count <= 10000 else { throw IntegrationError.schema }
            if let expected, expected != Int(count) { throw IntegrationError.invalid("Cursor 活动分页总数在查询期间变化，请重新刷新。") }; expected = Int(count)
            rows.append(contentsOf: events)
            if events.count < 100 { completed = true; break }
        }
        guard completed, let expected, rows.count == expected else { throw IntegrationError.incomplete }
        report.activity = try cursorActivity(rows)
        } catch {
            guard !report.allowances.isEmpty else { throw error }
            report.activity = cache(.cursor)?.activity ?? []
            report.note += " 活动读取失败，保留此前活动；此次额度查询已成功。请重新刷新活动。"
        }
        return report
    }
    static func cursorQuotaReport(_ object: [String: Any]) throws -> AIReport {
        guard let usage = object["individualUsage"] as? [String: [String: Any]] else { throw IntegrationError.schema }
        let reset = IntegrationNumber.date(object["billingCycleEnd"])
        var windows: [AIAllowance] = []
        if object["isUnlimited"] as? Bool != true {
            for key in ["overall", "plan", "onDemand"] {
                guard let row = usage[key], row["enabled"] as? Bool != false else { continue }
                if key == "plan" {
                    for (field, title) in [("autoPercentUsed", "Cursor Models"), ("apiPercentUsed", "Other Models")] {
                        if let percent = IntegrationNumber.percent(row[field]) { windows.append(AIAllowance(id: title, usedPercent: percent, resetsAt: reset, windowMinutes: nil)) }
                    }
                    if !windows.isEmpty { continue }
                }
                if let limit = IntegrationNumber.finite(row["limit"]), limit > 0, let used = IntegrationNumber.quantity(row["used"]), let percent = IntegrationNumber.percent(used / limit * 100) {
                    windows.append(AIAllowance(id: key, usedPercent: percent, resetsAt: reset, windowMinutes: nil))
                }
            }
        }
        return AIReport(provider: .cursor, allowances: windows, updatedAt: .now, note: "Cursor 个人仪表盘客户端接口（非稳定公开 API），账号范围、近 30 天活动。只读已有登录，不刷新凭据。超额进度按 100% 已用／0% 剩余显示。报告费用是 token API 估算值，不等于账单；缺失 token 字段不视作零。")
    }
    static func cursorActivity(_ rows: [[String: Any]]) throws -> [AIActivityRecord] {
        var result: [AIActivityRecord] = []
        for (index, row) in rows.enumerated() {
            guard let date = IntegrationNumber.date(row["timestamp"]) else { throw IntegrationError.schema }
            let usage = row["tokenUsage"] as? [String: Any] ?? [:]
            let cached = IntegrationNumber.count(usage["cacheReadTokens"]) + IntegrationNumber.count(usage["cacheWriteTokens"])
            let id = IntegrationNumber.hash("cursor-\(date.timeIntervalSince1970)-\(index)")
            let tokenFields = ["inputTokens","outputTokens","cacheReadTokens","cacheWriteTokens"].compactMap { IntegrationNumber.quantity(usage[$0]) }
            result.append(AIActivityRecord(id: id, session: "", date: date, input: IntegrationNumber.saturatedSum([IntegrationNumber.count(usage["inputTokens"]), cached]), output: IntegrationNumber.count(usage["outputTokens"]), cached: cached, requests: IntegrationNumber.quantity(row["requestsCosts"]) ?? 0, costUSD: IntegrationNumber.quantity(usage["totalCents"]).map { $0 / 100 }, tokenCoverage: tokenFields.count == 4 ? "complete":tokenFields.isEmpty ? "unavailable":"partial", requestsReported: IntegrationNumber.quantity(row["requestsCosts"]) != nil))
        }
        return result
    }
}
