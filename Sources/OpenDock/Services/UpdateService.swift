import AppKit
import Combine
import CryptoKit

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()
    @Published private(set) var state = "尚未检查"
    @Published private(set) var latestVersion: String?
    @Published private(set) var readyApp: URL?
    @Published private(set) var busy = false
    private var timer: Timer?
    private let api = URL(string: "https://api.github.com/repos/myh66/opendock/releases")!
    struct Asset: Decodable { var name: String; var browser_download_url: URL; var size: Int }
    struct Release: Decodable { var tag_name: String; var draft: Bool; var prerelease: Bool; var assets: [Asset] }
    func setAutomatic(_ enabled: Bool) {
        timer?.invalidate(); timer = nil
        guard enabled else { return }
        Task { await check(download: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in Task { @MainActor in await self?.check(download: true) } }
        timer?.tolerance = 600
    }
    nonisolated static func versionComponents(_ version: String) -> [Int] {
        guard version.range(of: "^v?[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$", options: .regularExpression) != nil else { return [] }
        return version.drop(while: { $0 == "v" }).split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []
    }
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = versionComponents(candidate), b = versionComponents(current)
        guard a.count == 3, b.count == 3 else { return false }
        for i in 0..<3 { if a[i] != b[i] { return a[i] > b[i] } }
        let suffixA = candidate.split(separator: "-",maxSplits:1).dropFirst().first.map(String.init)
        let suffixB = current.split(separator: "-",maxSplits:1).dropFirst().first.map(String.init)
        guard suffixA != suffixB else { return false }
        if suffixA == nil { return true }; if suffixB == nil { return false }
        return suffixA!.compare(suffixB!,options:.numeric) == .orderedDescending
    }
    nonisolated static func packageVersionMatches(version:String,tag:String,release:String,current:String)->Bool {
        let normalize:(String)->String = { String($0.drop(while:{ $0 == "v" })) }
        return versionComponents(version).count == 3 && versionComponents(version) == versionComponents(tag) && normalize(tag) == normalize(release) && isNewer(tag,than:current)
    }
    func check(download: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        state = "正在检查 GitHub Release…"
        do {
            var request = URLRequest(url: api); request.timeoutInterval = 20; request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data,response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.request }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            let current = Bundle.main.infoDictionary?["OpenDockReleaseTag"] as? String ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
            guard let release = releases.first(where: { !$0.draft && Self.isNewer($0.tag_name, than: current) }) else { state = "当前版本已是最新可用版本"; return }
            latestVersion = release.tag_name; state = "发现 \(release.tag_name)"
            guard download else { return }
            guard let zip = release.assets.first(where: { $0.name == "OpenDock-macOS.zip" }), let checksums = release.assets.first(where: { $0.name == "SHA256SUMS" }), zip.size <= 500_000_000 else { state = "此版本没有自动更新包，可在 GitHub 下载"; return }
            for asset in [zip,checksums] { guard asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com", asset.browser_download_url.path.hasPrefix("/myh66/opendock/releases/download/") else { throw UpdateError.invalidPackage } }
            state = "正在下载 \(release.tag_name)…"
            let (hashData,_) = try await URLSession.shared.data(from: checksums.browser_download_url)
            guard let line = String(data: hashData, encoding: .utf8)?.split(separator: "\n").first(where: { $0.hasSuffix("OpenDock-macOS.zip") }), let expected = line.split(whereSeparator: \.isWhitespace).first, expected.count == 64 else { throw UpdateError.invalidPackage }
            let (temporary,downloadResponse) = try await URLSession.shared.download(from: zip.browser_download_url)
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.request }
            let bytes = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let digest = SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined()
            guard digest == expected else { throw UpdateError.checksum }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenDock-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            let archive = directory.appendingPathComponent("update.zip"); try FileManager.default.moveItem(at: temporary, to: archive)
            // Reject traversal entries before extraction, even for our own release assets.
            let entries = try await run("/usr/bin/unzip",["-Z1",archive.path])
            guard entries.split(separator:"\n").allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator:"/").contains("..") && ($0.hasPrefix("OpenDock.app/") || $0.hasPrefix("__MACOSX/")) }) else { throw UpdateError.invalidPackage }
            _ = try await run("/usr/bin/ditto",["-x","-k",archive.path,directory.path])
            let app = directory.appendingPathComponent("OpenDock.app")
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "io.github.myh66.opendock", let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String, let tag = bundle.infoDictionary?["OpenDockReleaseTag"] as? String, Self.packageVersionMatches(version:version,tag:tag,release:release.tag_name,current:current) else { throw UpdateError.invalidPackage }
            _ = try await run("/usr/bin/codesign",["--verify","--strict",app.path])
            readyApp = app; state = "\(release.tag_name) 已下载并校验，准备安装"
        } catch { state = "更新失败：\(error.localizedDescription)" }
    }
    func install() {
        guard let readyApp, Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            let destination = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw UpdateError.notWritable }
            let backup = destination.deletingLastPathComponent().appendingPathComponent("OpenDock-before-update-\(UUID().uuidString).app")
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".OpenDock-update-\(UUID().uuidString).app")
            // Complete copying before moving the installed app; both renames stay on one volume.
            try FileManager.default.copyItem(at: readyApp, to: staged)
            try FileManager.default.moveItem(at: destination, to: backup)
            do { try FileManager.default.moveItem(at: staged, to: destination) }
            catch {
                do { try FileManager.default.moveItem(at: backup, to: destination) }
                catch { throw UpdateError.invalidPackage }
                throw error
            }
            // LaunchServices launches the replacement only after the current app exits.
            let script = "for i in {1..60}; do kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break; sleep 1; done\n/usr/bin/open " + Self.shellQuote(destination.path)
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/bin/zsh"); process.arguments = ["-c",script]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
            NSApp.terminate(nil)
        } catch { state = "安装失败：\(error.localizedDescription)" }
    }
    private static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    private func run(_ executable: String,_ arguments: [String]) async throws -> String {
        try await Task.detached(priority:.utility) {
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath:executable); process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now() + 60) { if process.isRunning { process.terminate() } }
            var data = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }; data.append(chunk)
                if data.count > 2_000_000 { process.terminate(); throw UpdateError.invalidPackage }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw UpdateError.invalidPackage }
            return String(decoding:data,as:UTF8.self)
        }.value
    }
}
private enum UpdateError: LocalizedError {
    case request, invalidPackage, checksum, notWritable
    var errorDescription: String? { switch self { case .request:return "无法读取 GitHub Release。";case .invalidPackage:return "更新包结构或签名无效。";case .checksum:return "下载文件的 SHA-256 校验不匹配。";case .notWritable:return "应用目录不可写，请手动下载并替换。" } }
}
