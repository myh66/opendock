import XCTest
import Darwin
@testable import OpenDock

/// All subprocesses are temporary, synthetic shell fixtures; no account CLI is invoked.
final class StatusBridgeTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opendock-status-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func script(_ body: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("synthetic-cli")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func capturedOutput(in directory: URL) throws -> (URL, FileHandle) {
        let url = directory.appendingPathComponent("output")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        return (url, try FileHandle(forWritingTo: url))
    }

    func testStatusPayloadReadsAllFragmentsUntilEOFAndDropsPrivateFields() throws {
        let pipe = Pipe()
        let payload = Data(#"{"rate_limits":{"five_hour":{"used_percentage":25}},"api_key":"SYNTHETIC_PRIVATE_SENTINEL","workspace":"SYNTHETIC_PRIVATE_SENTINEL","transcript":"SYNTHETIC_PRIVATE_SENTINEL"}"#.utf8)
        let finished = expectation(description: "synthetic writer completed")
        DispatchQueue.global(qos: .utility).async {
            defer { try? pipe.fileHandleForWriting.close(); finished.fulfill() }
            for start in stride(from: 0, to: payload.count, by: 7) {
                try? pipe.fileHandleForWriting.write(contentsOf: payload.subdata(in: start..<min(payload.count, start + 7)))
                _ = Darwin.poll(nil, 0, 1)
            }
        }
        let complete = try IntegrationStatusBridge.readPayload(from: pipe.fileHandleForReading)
        try pipe.fileHandleForReading.close()
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(complete, payload)
        let report = try IntegrationStatusBridge.reducedReport(complete, provider: .claude)
        XCTAssertEqual(report.allowances.first?.usedPercent, 25)
        let retained = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))
        XCTAssertFalse(retained.contains("SYNTHETIC_PRIVATE_SENTINEL"))
        XCTAssertFalse(retained.contains("api_key")); XCTAssertFalse(retained.contains("workspace"))
    }

    func testStatusInputBoundAndMalformedJSONFailWithoutPayloadInError() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 33))
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        XCTAssertThrowsError(try IntegrationStatusBridge.readPayload(from: pipe.fileHandleForReading, maximumBytes: 32))
        XCTAssertThrowsError(try IntegrationStatusBridge.reducedReport(Data("SYNTHETIC_PRIVATE_SENTINEL".utf8), provider: .claude)) { error in
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_PRIVATE_SENTINEL"))
        }
        XCTAssertThrowsError(try IntegrationStatusBridge.readPayload(from: .nullDevice, maximumBytes: Int.max))
    }

    func testPreviousCommandReceivesExactInputAndPreservesOnlyItsStdout() throws {
        try fixture { directory in
            let (url, output) = try capturedOutput(in: directory)
            defer { try? output.close() }
            let payload = Data("synthetic input\nsecond line\n".utf8)
            try IntegrationStatusBridge.runPrevious(command: "cat; printf 'SYNTHETIC_STDERR_SENTINEL' >&2", input: payload, output: output)
            XCTAssertEqual(try Data(contentsOf: url), payload)
        }
    }

    func testPreviousCommandBlockedInputHasBoundedTimeoutAndKillFallback() throws {
        try fixture { directory in
            let marker = directory.appendingPathComponent("pid")
            let (_, output) = try capturedOutput(in: directory)
            defer { try? output.close() }
            let executable = try script("trap '' TERM\nprintf '%s' \"$$\" > " + quote(marker.path) + "\nwhile :; do :; done", in: directory)
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try IntegrationStatusBridge.runPrevious(command: "exec " + quote(executable.path), input: Data(repeating: 65, count: 4_000_000), output: output, timeout: 3, terminationGrace: 0.05))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 6)
            try assertStopped(marker: marker)
        }
    }

    func testPreviousCommandClosingStdinDoesNotRaiseSIGPIPE() throws {
        try fixture { directory in
            let (_, output) = try capturedOutput(in: directory)
            defer { try? output.close() }
            XCTAssertThrowsError(try IntegrationStatusBridge.runPrevious(command: "exit 0", input: Data(repeating: 65, count: 4_000_000), output: output, timeout: 0.5))
        }
    }

    func testCodexFragmentedJSONLOnlySendsReadOnlyHandshakeAndQuotaRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = directory.appendingPathComponent("requests")
        let executable = try script("""
        [ "$1" = app-server ] || exit 1
        IFS= read -r first
        printf '%s\\n' "$first" > \(quote(requests.path))
        printf '{"id":1,"res'
        /bin/sleep 0.02
        printf 'ult":{}}\\n{"method":"synthetic.notification","params":{}}\\n'
        IFS= read -r second
        IFS= read -r third
        printf '%s\\n%s\\n' "$second" "$third" >> \(quote(requests.path))
        printf '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}\\n'
        """, in: directory)
        let reply = try await CodexQuotaCommand.read(executable: executable.path, timeout: 10)
        XCTAssertEqual(reply["id"] as? Int, 2)
        let lines = try String(contentsOf: requests, encoding: .utf8).split(separator: "\n")
        let objects = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects.compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/rateLimits/read"])
        let text = try String(contentsOf: requests, encoding: .utf8)
        XCTAssertFalse(text.contains("login")); XCTAssertFalse(text.contains("api_key")); XCTAssertFalse(text.contains("session/create"))
        XCTAssertEqual(AIAdapters.codexAllowances(reply).first?.usedPercent, 25)
    }

    func testCodexRepeatedInitializeCannotFillItsStdinPipe() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try script("""
        IFS= read -r first
        n=0
        while [ "$n" -lt 1000 ]; do printf '{"id":1,"result":{}}\\n'; n=$((n + 1)); done
        IFS= read -r second
        IFS= read -r third
        printf '{"id":2,"result":{"rateLimits":{}}}\\n'
        """, in: directory)
        let reply = try await CodexQuotaCommand.read(executable: executable.path, timeout: 10)
        XCTAssertEqual(reply["id"] as? Int, 2)
    }

    func testCodexTimeoutKillsChildIgnoringSIGTERM() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pid")
        let executable = try script("trap '' TERM\nprintf '%s' \"$$\" > " + quote(marker.path) + "\nwhile :; do :; done", in: directory)
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await CodexQuotaCommand.read(executable: executable.path, timeout: 3, terminationGrace: 0.05); XCTFail("Expected timeout") }
        catch { XCTAssertFalse(error.localizedDescription.contains(executable.path)) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 6)
        try assertStopped(marker: marker)
    }

    func testCodexParentCancellationPropagatesToDetachedChild() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pid")
        let executable = try script("trap '' TERM\nprintf '%s' \"$$\" > " + quote(marker.path) + "\nwhile :; do :; done", in: directory)
        let task = Task { try await CodexQuotaCommand.read(executable: executable.path, timeout: 20, terminationGrace: 0.05) }
        defer { task.cancel() }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
        try assertStopped(marker: marker)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opendock-status-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func assertStopped(marker: URL) throws {
        let text = try String(contentsOf: marker, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(text))
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) != 0, errno == ESRCH { return }
            _ = Darwin.poll(nil, 0, 10)
        }
        XCTFail("Synthetic child survived TERM and KILL")
        _ = Darwin.kill(pid, SIGKILL)
    }
}
