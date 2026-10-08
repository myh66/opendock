import AppKit
import Foundation
import Darwin

/// Vendor status-line payloads are reduced to allowance numbers before persistence.
/// The previous command receives its normal stdin and its output is preserved.
enum IntegrationStatusBridge {
    struct Backup:Codable { var path:String; var command:String; var original:Data? }
    static func configURL(_ provider:AIProvider)->URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(provider == .claude ? ".claude/settings.json":".gemini/antigravity-cli/settings.json")
    }
    static func installed(_ provider:AIProvider)->Bool { IntegrationDisk.read(Backup.self,key:"ai-status-backup-" + provider.rawValue) != nil }
    static func connect(_ provider:AIProvider) throws {
        guard [.claude,.antigravity].contains(provider),Bundle.main.bundleURL.pathExtension == "app",let executable = Bundle.main.executableURL else { throw IntegrationError.invalid("请安装并从 OpenDock.app 开启状态栏连接。") }
        let url = configURL(provider)
        var settings = try readSettings(url)
        let command = shellQuote(executable.path) + " --ai-status " + provider.rawValue
        if let existing = IntegrationDisk.read(Backup.self,key:"ai-status-backup-" + provider.rawValue), (settings["statusLine"] as? [String:Any])?["command"] as? String == existing.command {
            settings["statusLine"] = ["type":"command","command":command]
            try writeSettings(settings,to:url)
            var updated = existing; updated.command = command; try IntegrationDisk.write(updated,key:"ai-status-backup-" + provider.rawValue)
            return
        }
        let original = settings["statusLine"].flatMap { try? JSONSerialization.data(withJSONObject:$0,options:[.fragmentsAllowed,.sortedKeys]) }
        let backup = Backup(path:url.path,command:command,original:original)
        try IntegrationDisk.write(backup,key:"ai-status-backup-" + provider.rawValue)
        settings["statusLine"] = ["type":"command","command":command]
        do { try writeSettings(settings,to:url) } catch { IntegrationDisk.remove(key:"ai-status-backup-" + provider.rawValue); throw error }
    }
    @discardableResult static func disconnect(_ provider:AIProvider) throws -> Bool {
        guard let backup = IntegrationDisk.read(Backup.self,key:"ai-status-backup-" + provider.rawValue) else { return true }
        let url = URL(fileURLWithPath:backup.path); var settings = try readSettings(url)
        guard (settings["statusLine"] as? [String:Any])?["command"] as? String == backup.command else { return false }
        if let original = backup.original { settings["statusLine"] = try JSONSerialization.jsonObject(with:original,options:.fragmentsAllowed) } else { settings.removeValue(forKey:"statusLine") }
        try writeSettings(settings,to:url); IntegrationDisk.remove(key:"ai-status-backup-" + provider.rawValue); IntegrationDisk.remove(key:"ai-bridge-" + provider.rawValue)
        return true
    }
    static func runIfRequested()->Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of:"--ai-status"), args.indices.contains(flag + 1), let provider = AIProvider(rawValue:args[flag + 1]), [.claude,.antigravity].contains(provider) else { return false }
        do {
            let data = try readPayload(from: FileHandle.standardInput)
            let report = try reducedReport(data, provider: provider)
            if !report.allowances.isEmpty { try IntegrationDisk.write(report,key:"ai-bridge-" + provider.rawValue) }
            if let backup = IntegrationDisk.read(Backup.self,key:"ai-status-backup-" + provider.rawValue), let original = backup.original,
               let value = try? JSONSerialization.jsonObject(with:original) as? [String:Any], let command = value["command"] as? String, !command.isEmpty, command != backup.command {
                try runPrevious(command: command, input: data)
            } else {
                let quota = report.allowances.prefix(3).map { "\($0.id) \(Int(100 - $0.usedPercent))%" }.joined(separator:" · ")
                print("\(provider.title)" + (quota.isEmpty ? "":" · " + quota))
            }
        } catch { /* A status-line bridge must not leak payload or credentials into terminal errors. */ }
        return true
    }

    /// A pipe may return a short read before EOF. Never parse or forward a partial payload.
    static func readPayload(from handle: FileHandle, maximumBytes: Int = 4_000_000) throws -> Data {
        guard (0...4_000_000).contains(maximumBytes) else { throw IntegrationError.schema }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(32_768, maximumBytes - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - data.count else { throw IntegrationError.incomplete }
            data.append(chunk)
        }
        return data
    }

    static func reducedReport(_ data: Data, provider: AIProvider) throws -> AIReport {
        guard data.count <= 4_000_000, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw IntegrationError.schema }
        return AIAdapters.statusReport(object, provider: provider)
    }

    /// Keep the previous status line's stdout, but bound both blocked stdin and execution.
    static func runPrevious(command: String, input: Data, output: FileHandle = .standardOutput,
                            timeout: TimeInterval = 3, terminationGrace: TimeInterval = 0.25) throws {
        guard input.count <= 4_000_000 else { throw IntegrationError.incomplete }
        let process = Process(), pipe = Pipe()
        let child = StatusBridgeChild(timeout: timeout, terminationGrace: terminationGrace)
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardInput = pipe; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        defer { child.stop(); try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        do { try process.run() } catch { throw StatusBridgeProcessError.failed }
        child.attach(process)
        try? pipe.fileHandleForReading.close()
        try StatusBridgePipe.configure(pipe.fileHandleForWriting, writing: true)
        try StatusBridgePipe.write(input, to: pipe.fileHandleForWriting, child: child)
        try pipe.fileHandleForWriting.close()
        while process.isRunning {
            try child.check()
            // The child has no stdout pipe to drain here; a bounded poll also observes cancellation.
            _ = Darwin.poll(nil, 0, 20)
        }
    }
    private static func readSettings(_ url:URL) throws -> [String:Any] {
        guard FileManager.default.fileExists(atPath:url.path) else { return [:] }
        let data = try Data(contentsOf:url); guard data.count <= 4_000_000,let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw IntegrationError.invalid("CLI 设置不是受支持的 JSON，未修改。") }; return object
    }
    private static func writeSettings(_ settings:[String:Any],to url:URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONSerialization.data(withJSONObject:settings,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private static func shellQuote(_ value:String)->String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
}

enum CodexQuotaCommand {
    static func read(executable: String, timeout: TimeInterval = 20, terminationGrace: TimeInterval = 0.25) async throws -> [String: Any] {
        let child = StatusBridgeChild(timeout: timeout, terminationGrace: terminationGrace)
        let worker = Task.detached(priority: .utility) { () throws -> [String: Any] in
            try child.check()
            guard executable.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:executable) else { throw IntegrationError.invalid("请选择已安装的 Codex 可执行文件。") }
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath:executable); process.arguments = ["app-server"]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            defer {
                child.stop()
                try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
                try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            }
            do { try process.run() } catch { throw IntegrationError.invalid("无法启动已选择的 Codex CLI。") }
            child.attach(process)
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            try StatusBridgePipe.configure(input.fileHandleForWriting, writing: true)
            try StatusBridgePipe.configure(output.fileHandleForReading, writing: false)
            func send(_ value: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
                try StatusBridgePipe.write(data, to: input.fileHandleForWriting, child: child)
            }
            try send(["id":1,"method":"initialize","params":["clientInfo":["name":"opendock","version":"0.2.0"],"capabilities":["experimentalApi":true]]])
            var buffer = Data(), total = 0, initialized = false
            while true {
                let chunk = try StatusBridgePipe.read(from: output.fileHandleForReading, child: child)
                guard !chunk.isEmpty else { break }
                guard chunk.count <= 2_000_000 - total else { throw IntegrationError.incomplete }
                buffer.append(chunk); total += chunk.count
                while let newline = buffer.firstIndex(of:10) {
                    let line = buffer.prefix(upTo:newline); buffer.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any],let id = object["id"] as? Int else { continue }
                    if id == 1, !initialized {
                        guard object["error"] == nil else { throw IntegrationError.invalid("此 Codex CLI 不支持 app-server 初始化。") }
                        initialized = true
                        try send(["method":"initialized"])
                        try send(["id":2,"method":"account/rateLimits/read","params":[:]])
                    } else if id == 2, initialized {
                        guard object["error"] == nil else { throw IntegrationError.invalid("Codex 额度查询失败，请在 Codex 登录 ChatGPT 账号后重试。") }
                        try child.check()
                        return object
                    }
                }
            }
            throw IntegrationError.invalid("Codex 额度查询超时或 CLI 已退出，保留上次成功数据。")
        }
        return try await withTaskCancellationHandler(operation: {
            do { let result = try await worker.value; try Task.checkCancellation(); return result }
            catch is CancellationError { throw CancellationError() }
            catch is StatusBridgeProcessError {
                throw IntegrationError.invalid("Codex 额度查询超时或 CLI 已退出，保留上次成功数据。")
            }
        }, onCancel: {
            child.stop(cancelled: true)
            worker.cancel()
        })
    }
}

private enum StatusBridgeProcessError: Error { case timeout, failed }

/// The detached reader and its parent cancellation handler share one bounded child lifetime.
private final class StatusBridgeChild: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var killScheduled = false
    private var timeoutWork: DispatchWorkItem?
    private var deadline = TimeInterval.greatestFiniteMagnitude
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval

    init(timeout: TimeInterval, terminationGrace: TimeInterval) {
        let boundedTimeout = timeout.isFinite ? min(60, max(0.01, timeout)) : 20
        self.timeout = boundedTimeout
        self.terminationGrace = terminationGrace.isFinite ? min(1, max(0.01, terminationGrace)) : 0.25
    }

    func attach(_ process: Process) {
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        // Process.run may spend time in macOS launch services before a child exists.
        // Start the execution deadline once the child is attached; cancellation still
        // records immediately and terminates it as soon as launch finishes.
        lock.lock(); self.process = process; deadline = ProcessInfo.processInfo.systemUptime + timeout; timeoutWork = work; let wasCancelled = cancelled; lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
        if wasCancelled { stop(cancelled: true) }
    }

    func check() throws {
        lock.lock(); let wasCancelled = cancelled; let expires = deadline; lock.unlock()
        if wasCancelled || Task<Never, Never>.isCancelled { stop(cancelled: true); throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= expires { stop(); throw StatusBridgeProcessError.timeout }
    }

    func stop(cancelled: Bool = false) {
        lock.lock()
        self.cancelled = self.cancelled || cancelled
        timeoutWork?.cancel(); timeoutWork = nil
        let target = killScheduled ? nil : process
        if target != nil { killScheduled = true }
        lock.unlock()
        guard let target else { return }
        if target.isRunning { target.terminate() }
        // A CLI may ignore SIGTERM. Keep it alive only for this short grace period.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) {
            if target.isRunning { _ = Darwin.kill(target.processIdentifier, SIGKILL) }
        }
    }
}

/// Never use availableData or a blocking pipe write: a stubborn process can keep them open.
private enum StatusBridgePipe {
    static func configure(_ handle: FileHandle, writing: Bool) throws {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw StatusBridgeProcessError.failed }
        if writing, fcntl(fd, F_SETNOSIGPIPE, 1) < 0 { throw StatusBridgeProcessError.failed }
    }

    private static func ready(_ fd: Int32, event: Int16, child: StatusBridgeChild) throws {
        while true {
            try child.check()
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = Darwin.poll(&descriptor, 1, 20)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw StatusBridgeProcessError.failed }
                return
            }
            if result < 0, errno != EINTR { throw StatusBridgeProcessError.failed }
        }
    }

    static func write(_ data: Data, to handle: FileHandle, child: StatusBridgeChild) throws {
        var offset = 0
        while offset < data.count {
            try ready(handle.fileDescriptor, event: Int16(POLLOUT), child: child)
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), min(32_768, data.count - offset))
            }
            if count > 0 { offset += count }
            else if count < 0, errno != EINTR, errno != EAGAIN { throw StatusBridgeProcessError.failed }
        }
    }

    static func read(from handle: FileHandle, child: StatusBridgeChild) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32_768)
        while true {
            try ready(handle.fileDescriptor, event: Int16(POLLIN), child: child)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno != EINTR, errno != EAGAIN { throw StatusBridgeProcessError.failed }
        }
    }
}
