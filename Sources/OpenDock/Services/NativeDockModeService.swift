import AppKit
import CoreFoundation

/// Replacement mode keeps a recoverable snapshot of only the preferences it owns.
/// Restoration does not rewrite pinned apps or unrelated settings.
@MainActor
final class NativeDockModeService {
    static let shared = NativeDockModeService()
    private let domain = "com.apple.dock" as CFString
    private let keys = ["autohide", "autohide-delay", "autohide-time-modifier"]
    private let backupURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenDock/replacement-mode.plist")
    private var active = false
    private var transitioning = false
    private var requested = false
    var hasRecoverySnapshot: Bool { FileManager.default.fileExists(atPath: backupURL.path) }
    private init() { active = FileManager.default.fileExists(atPath: backupURL.path) }

    func update(mode: DockMode) {
        requested = mode == .replacement
        guard !transitioning else { return }
        transitioning = true
        Task {
            defer { transitioning = false }
            while requested != active {
                let target = requested
                do {
                    try await NativeDockService.performDockMutation {
                        if target { try await self.enter() } else { try await self.restore() }
                    }
                    active = target
                } catch { AppStore.shared.errorMessage = "Dock 替换模式设置失败：\(error.localizedDescription)"; requested = active; break }
            }
        }
    }
    func restoreForTermination() async throws {
        requested = false
        // The same mutation queue waits for a pending mode change/native profile write.
        try await NativeDockService.performDockMutation { try await self.restore() }
        active = false
    }
    private func enter() async throws {
        for key in keys { guard !CFPreferencesAppValueIsForced(key as CFString, domain) else { throw NativeDockError.managedPreferences } }
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw NativeDockError.preferencesUnavailable }
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            var existing: [String: Any] = [:]
            var missing: [String] = []
            for key in keys {
                if let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) { existing[key] = value }
                else { missing.append(key) }
            }
            let data = try PropertyListSerialization.data(fromPropertyList: ["version": 1, "values": existing, "missing": missing], format: .binary, options: 0)
            try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: backupURL, options: .atomic)
        }
        _ = try Self.validateSnapshot(try PropertyListSerialization.propertyList(from: Data(contentsOf: backupURL), format: nil))
        do {
        CFPreferencesSetValue("autohide" as CFString, NSNumber(value: true), domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("autohide-delay" as CFString, NSNumber(value: 86400.0), domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("autohide-time-modifier" as CFString, NSNumber(value: 0.0), domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw NativeDockError.preferencesUnavailable }
        try await restart(expected: ["autohide": NSNumber(value: true), "autohide-delay": NSNumber(value: 86400.0), "autohide-time-modifier": NSNumber(value: 0.0)], missing: [])
        } catch {
            let change = error.localizedDescription
            do { try await restore() } catch { throw NativeDockError.rollbackFailed(change: change, rollback: error.localizedDescription) }
            throw NativeDockError.changeFailed(change)
        }
    }
    private func restore() async throws {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return }
        let data = try Data(contentsOf: backupURL)
        let (values, missing) = try Self.validateSnapshot(try PropertyListSerialization.propertyList(from: data, format: nil))
        for key in keys { guard !CFPreferencesAppValueIsForced(key as CFString, domain) else { throw NativeDockError.managedPreferences } }
        for key in keys {
            CFPreferencesSetValue(key as CFString, missing.contains(key) ? nil : values[key] as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw NativeDockError.preferencesUnavailable }
        try await restart(expected: values, missing: missing)
        try FileManager.default.removeItem(at: backupURL)
    }
    nonisolated static func validateSnapshot(_ object: Any) throws -> ([String: Any], [String]) {
        let owned: Set<String> = ["autohide", "autohide-delay", "autohide-time-modifier"]
        guard let snapshot = object as? [String: Any], snapshot["version"] as? Int == 1, let values = snapshot["values"] as? [String: Any], let missing = snapshot["missing"] as? [String],
              Set(missing).count == missing.count, Set(values.keys).isDisjoint(with: Set(missing)), Set(values.keys).union(missing) == owned else { throw NativeDockError.invalidBackup }
        for (key, value) in values {
            guard let number = value as? NSNumber else { throw NativeDockError.invalidBackup }
            if key == "autohide" { guard [0,1].contains(number.doubleValue) else { throw NativeDockError.invalidBackup } }
            else { guard number.doubleValue.isFinite, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw NativeDockError.invalidBackup } }
        }
        return (values, missing)
    }
    private func restart(expected: [String: Any], missing: [String]) async throws {
        let previous = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); process.arguments = ["-u", NSUserName(), "Dock"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in if p.terminationStatus == 0 { c.resume() } else { c.resume(throwing: NativeDockError.restartFailed) } }
            do { try process.run() } catch { c.resume(throwing: error) }
        }
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 200_000_000)
            let current = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier))
            guard !current.isEmpty, previous.isDisjoint(with: current), CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { continue }
            var actual: [String: Any] = [:]
            for key in keys { if let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) { actual[key] = value } }
            if NSDictionary(dictionary: actual).isEqual(to: expected), missing.allSatisfy({ actual[$0] == nil }) { return }
        }
        throw NativeDockError.verificationFailed
    }
}
