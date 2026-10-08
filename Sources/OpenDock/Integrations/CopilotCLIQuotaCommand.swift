import Foundation
import Darwin

/// Independently implemented against github/copilot-sdk nodejs/src/client.ts
/// and generated/rpc.ts. Protocol version 3; vscode-jsonrpc Content-Length.
enum CopilotRPCFrame {
    static func encode(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        guard body.count <= 2_000_000 else { throw IntegrationError.incomplete }
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
    static func next(_ buffer: inout Data) throws -> [String: Any]? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { if buffer.count > 8192 { throw IntegrationError.schema }; return nil }
        guard separator.lowerBound <= 8192, let header = String(data: buffer.prefix(upTo: separator.lowerBound), encoding: .utf8) else { throw IntegrationError.schema }
        let lengths = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }
        guard lengths.count == 1, let length = lengths.first, length > 0, length <= 2_000_000 else { throw IntegrationError.schema }
        let end = separator.upperBound + length
        guard buffer.count >= end else { return nil }
        let body = buffer.subdata(in: separator.upperBound..<end)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any], object["jsonrpc"] as? String == "2.0" else { throw IntegrationError.schema }
        buffer.removeSubrange(buffer.startIndex..<end)
        // Normalize indexes after removal so subsequent frame offsets start at 0.
        buffer = Data(buffer)
        return object
    }
}

enum CopilotCLIQuotaCommand {
    static func read(executable: String) async throws -> [String: Any] {
        try await Task.detached(priority: .utility) {
            guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw IntegrationError.invalid("请选择已安装的 Copilot CLI 可执行文件。") }
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--headless", "--stdio", "--no-auto-update", "--log-level", "error"]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var environment: [String: String] = [:]
            for key in ["HOME", "PATH", "TMPDIR", "XDG_CONFIG_HOME", "GH_CONFIG_DIR"] { environment[key] = ProcessInfo.processInfo.environment[key] }
            environment["CI"] = "1"; environment["TERM"] = "dumb"; environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_BROWSER"] = "false"
            process.environment = environment
            do { try process.run() } catch { throw IntegrationError.invalid("无法启动 Copilot CLI。") }
            let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25, execute: timeout)
            defer {
                try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit(); timeout.cancel()
            }
            var buffer = Data(), received = 0
            func send(_ id: Int, _ method: String) throws { try input.fileHandleForWriting.write(contentsOf: CopilotRPCFrame.encode(["jsonrpc": "2.0", "id": id, "method": method, "params": [:]])) }
            func response(_ id: Int) throws -> [String: Any] {
                for _ in 0..<64 {
                    var message: [String: Any]?
                    while message == nil {
                        message = try CopilotRPCFrame.next(&buffer)
                        if message != nil { break }
                        let chunk = output.fileHandleForReading.availableData
                        guard !chunk.isEmpty else { throw IntegrationError.invalid("Copilot CLI 只读协议中断或超时。请在 CLI 中确认登录和版本。") }
                        received += chunk.count; guard received <= 4_000_000 else { throw IntegrationError.incomplete }; buffer.append(chunk)
                    }
                    guard let object = message else { continue }
                    if let incomingID = object["id"], object["method"] != nil {
                        // Refuse any unsolicited user/tool/permission request.
                        try input.fileHandleForWriting.write(contentsOf: CopilotRPCFrame.encode(["jsonrpc": "2.0", "id": incomingID, "error": ["code": -32601, "message": "OpenDock only reads account quota"]])); continue
                    }
                    if (object["id"] as? Int) == id { return object }
                }
                throw IntegrationError.schema
            }
            try send(1, "connect")
            var handshake = try response(1)
            if ((handshake["error"] as? [String: Any])?["code"] as? Int) == -32601 { try send(2, "ping"); handshake = try response(2) }
            guard let version = IntegrationNumber.finite((handshake["result"] as? [String: Any])?["protocolVersion"]), version == 3 else { throw IntegrationError.invalid("需要支持 SDK 协议版本 3 的 Copilot CLI。当前版本未通过只读协议检查。") }
            try send(3, "account.getQuota")
            let reply = try response(3)
            guard reply["error"] == nil, let result = reply["result"] as? [String: Any] else { throw IntegrationError.invalid("Copilot account.getQuota 未返回额度。请在 CLI 中重新登录或检查账号计划。") }
            return result
        }.value
    }
}
