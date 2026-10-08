import AppKit
import CoreFoundation
import Foundation

/// Changes only the pinned application list. Other Dock preferences and pinned
/// folders remain untouched. No operation runs until a user explicitly applies
/// a native profile or restores its backup.
final class NativeDockService {
    private static let mutations = NativeDockMutationQueue()
    private static let domain = "com.apple.dock" as CFString
    let backupURL: URL

    init(backupURL: URL? = nil) {
        self.backupURL = backupURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenDock/native-dock-backup.plist")
    }

    var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    static func performDockMutation(_ operation: () async throws -> Void) async throws {
        try await mutations.perform(operation)
    }

    func captureProfile(name: String) throws -> DockProfile {
        let preferences = try Self.readPreferences()
        let tiles: [[String: Any]]
        if let value = preferences["persistent-apps"] {
            guard let list = value as? [[String: Any]] else { throw NativeDockError.invalidPinnedList }
            tiles = list
        } else { tiles = [] }
        return DockProfile(name: name, kind: .native, items: try Self.items(from: tiles))
    }

    func apply(_ profile: DockProfile, smooth: Bool = false) async throws {
        guard profile.kind == .native else { throw NativeDockError.notNativeProfile }
        let tiles = try Self.tiles(for: profile.items, validateApplications: true)
        try await Self.mutations.perform {
            let originals = try Self.readPreferences()
            try self.saveBackup(originals)
            let transition = smooth ? await DockTransitionService.shared.begin() : nil
            do { try await Self.replacePinnedApps(tiles, rollback: originals["persistent-apps"]) }
            catch { await DockTransitionService.shared.end(transition); throw error }
            await DockTransitionService.shared.end(transition)
        }
    }

    func restoreLastBackup() async throws {
        try await Self.mutations.perform {
            let data = try Data(contentsOf: self.backupURL)
            guard let backup = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  (backup["version"] as? Int) == 1,
                  let preferences = backup["preferences"] as? [String: Any] else { throw NativeDockError.invalidBackup }
            let original = try Self.readPreferences()
            let tiles = preferences["persistent-apps"]
            guard tiles == nil || tiles is [[String: Any]] else { throw NativeDockError.invalidBackup }
            try await Self.replacePinnedApps(tiles, rollback: original["persistent-apps"])
        }
    }

    private func saveBackup(_ preferences: [String: Any]) throws {
        let folder = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let envelope: [String: Any] = ["version": 1, "capturedAt": Date(), "preferences": preferences]
        let data = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
        try data.write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }

    private static func readPreferences() throws -> [String: Any] {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw NativeDockError.preferencesUnavailable
        }
        guard let values = CFPreferencesCopyMultiple(nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] else {
            throw NativeDockError.preferencesUnavailable
        }
        return values
    }

    private static func writePinnedApps(_ value: Any?) throws {
        guard !CFPreferencesAppValueIsForced("persistent-apps" as CFString, domain) else { throw NativeDockError.managedPreferences }
        CFPreferencesSetValue("persistent-apps" as CFString, value as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw NativeDockError.preferencesUnavailable }
    }

    private static func replacePinnedApps(_ tiles: Any?, rollback original: Any?) async throws {
        // A managed layout cannot be changed, so fail before entering rollback.
        guard !CFPreferencesAppValueIsForced("persistent-apps" as CFString, domain) else { throw NativeDockError.managedPreferences }
        do {
            try writePinnedApps(tiles)
            try await restartDockAndVerify(expected: tiles)
        } catch {
            let failure = error.localizedDescription
            do {
                // Recovery must finish even if the applying task was cancelled.
                try await Task.detached {
                    try writePinnedApps(original)
                    try await restartDockAndVerify(expected: original)
                }.value
            } catch {
                throw NativeDockError.rollbackFailed(change: failure, rollback: error.localizedDescription)
            }
            throw NativeDockError.changeFailed(failure)
        }
    }

    private static func restartDockAndVerify(expected: Any?) async throws {
        let previousPIDs = await MainActor.run { Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier)) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-u", NSUserName(), "Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw NativeDockError.restartFailed }
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 200_000_000)
            let currentPIDs = await MainActor.run { Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier)) }
            guard !currentPIDs.isEmpty, previousPIDs.isDisjoint(with: currentPIDs) else { continue }
            let actual = try readPreferences()["persistent-apps"]
            if try fingerprint(actual) == fingerprint(expected) { return }
        }
        throw NativeDockError.verificationFailed
    }

    /// Pure conversion helpers make format verification possible without writing
    /// preferences or restarting the system Dock.
    static func items(from tiles: [[String: Any]]) throws -> [DockItem] {
        try tiles.map { tile in
            let tileType = tile["tile-type"] as? String ?? ""
            if tileType == "spacer-tile" || tileType == "small-spacer-tile" {
                return DockItem(kind: .spacer, title: "间隔", configuration: ["size": tileType == "small-spacer-tile" ? "small" : "regular"])
            }
            guard tileType == "file-tile", let path = applicationPath(in: tile), path.lowercased().hasSuffix(".app") else {
                throw NativeDockError.unsupportedTile(tileType)
            }
            let data = tile["tile-data"] as? [String: Any] ?? [:]
            let encoded = try PropertyListSerialization.data(fromPropertyList: tile, format: .binary, options: 0).base64EncodedString()
            return DockItem(kind: .app, title: data["file-label"] as? String ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                            target: path, configuration: ["nativeTile": encoded])
        }
    }

    static func tiles(for items: [DockItem], validateApplications: Bool = false) throws -> [[String: Any]] {
        guard items.count <= 500 else { throw NativeDockError.tooManyItems }
        return try items.map { item in
            switch item.kind {
            case .spacer:
                return ["tile-type": item.configuration["size"] == "small" ? "small-spacer-tile" : "spacer-tile", "tile-data": [String: Any]()]
            case .app:
                let url = URL(fileURLWithPath: (item.target as NSString).expandingTildeInPath).standardizedFileURL
                guard item.target.hasPrefix("/") || item.target.hasPrefix("~/"), url.path.lowercased().hasSuffix(".app") else { throw NativeDockError.invalidApplication(item.target) }
                if validateApplications {
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
                          Bundle(url: url)?.bundleIdentifier != nil else { throw NativeDockError.invalidApplication(url.path) }
                }
                if let encoded = item.configuration["nativeTile"], let data = Data(base64Encoded: encoded),
                   let original = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   original["tile-type"] as? String == "file-tile", applicationPath(in: original) == url.path {
                    return original
                }
                var metadata: [String: Any] = ["file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15],
                                                "file-label": item.title.isEmpty ? url.deletingPathExtension().lastPathComponent : item.title,
                                                "file-type": 41]
                if let identifier = Bundle(url: url)?.bundleIdentifier { metadata["bundle-identifier"] = identifier }
                return ["tile-type": "file-tile", "tile-data": metadata]
            default: throw NativeDockError.unsupportedItem
            }
        }
    }

    private static func applicationPath(in tile: [String: Any]) -> String? {
        guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
              let location = file["_CFURLString"] as? String else { return nil }
        if let url = URL(string: location), url.isFileURL { return url.standardizedFileURL.path }
        if location.hasPrefix("/") { return URL(fileURLWithPath: location).standardizedFileURL.path }
        return nil
    }

    private enum PinnedTileSignature: Equatable {
        case spacer(String), application(String), other(NSDictionary)
    }

    private static func fingerprint(_ value: Any?) throws -> [PinnedTileSignature] {
        guard let value else { return [] }
        guard let tiles = value as? [[String: Any]] else { throw NativeDockError.verificationFailed }
        return tiles.map { tile in
            let type = tile["tile-type"] as? String ?? ""
            if type == "spacer-tile" || type == "small-spacer-tile" { return .spacer(type) }
            if type == "file-tile", let path = applicationPath(in: tile) { return .application(path) }
            // Existing tiles from a future macOS version still belong in the
            // backup. Restore can verify them by content even though profile
            // capture deliberately rejects editing their unsupported format.
            return .other(NSDictionary(dictionary: tile))
        }
    }
}

private actor NativeDockMutationQueue {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    func perform(_ operation: () async throws -> Void) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await operation()
    }
}

enum NativeDockError: LocalizedError {
    case notNativeProfile, preferencesUnavailable, invalidPinnedList, managedPreferences, invalidBackup, unsupportedItem, tooManyItems
    case unsupportedTile(String), invalidApplication(String), restartFailed, verificationFailed
    case changeFailed(String), rollbackFailed(change: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .notNativeProfile: return "请选择 macOS Dock 布局。"
        case .preferencesUnavailable: return "无法读取或保存 macOS Dock 偏好设置。"
        case .invalidPinnedList: return "当前 macOS Dock 应用列表格式不受支持，无法安全读取。"
        case .managedPreferences: return "此 Mac 的 Dock 布局受管理员管理，无法修改。"
        case .invalidBackup: return "macOS Dock 备份损坏或版本不受支持。"
        case .unsupportedItem: return "macOS Dock 布局只支持应用与间隔。"
        case .tooManyItems: return "布局项目超过允许数量。"
        case .unsupportedTile(let value): return "当前 Dock 包含不受支持的项目（\(value)），请先手动移除。"
        case .invalidApplication(let path): return "应用不存在或不是有效的 .app：\(path)"
        case .restartFailed: return "无法重新启动 macOS Dock。"
        case .verificationFailed: return "macOS Dock 重启后的布局验证失败。"
        case .changeFailed(let reason): return "布局应用失败，已恢复原布局。\(reason)"
        case .rollbackFailed(let change, let rollback): return "布局应用失败（\(change)），自动恢复也失败（\(rollback)）。原布局备份仍保存在本机。"
        }
    }
}
