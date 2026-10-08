import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore(storageURL: ProcessInfo.processInfo.arguments.contains("--ui-test") ? ProcessInfo.processInfo.environment["OPENDOCK_TEST_ARCHIVE"].map { URL(fileURLWithPath: $0) } : nil)
    @Published var archive: DockArchive { didSet { persist() } }
    @Published var selectedID: UUID?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var applyingNative = false
    @Published var widgetLibraryPresented = false
    @Published var settingsPresented = false
    @Published var requestedPage: String?
    @Published var tourPresented = false
    let nativeService = NativeDockService()
    private var persistenceBlocked = false
    private var pendingNativeOperations = 0
    private var lastNativeChange = Date.distantPast
    private var nativeWatchTimer: Timer?
    let storageURL: URL

    var profiles: [DockProfile] { archive.profiles }
    var selected: DockProfile? { profiles.first { $0.id == selectedID } }
    var activeCustom: DockProfile? { profiles.first { $0.id == archive.activeCustomID && $0.kind == .custom } }
    var settings: DockSettings {
        get { archive.settings }
        set { archive.settings = newValue }
    }

    init(storageURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenDock", isDirectory: true)
        self.storageURL = storageURL ?? base.appendingPathComponent("layouts.json")
        var loadError: String?
        var blocked = false
        var loaded: DockArchive?
        if FileManager.default.fileExists(atPath: self.storageURL.path) {
            do { loaded = try JSONDecoder().decode(DockArchive.self, from: Data(contentsOf: self.storageURL)).validated() }
            catch {
                let backup = self.storageURL.deletingLastPathComponent().appendingPathComponent("layouts-unreadable-\(UUID().uuidString).json")
                do {
                    try FileManager.default.copyItem(at: self.storageURL, to: backup)
                    loadError = "布局文件无法读取，已保留副本：\(backup.lastPathComponent)。\n\(error.localizedDescription)"
                } catch { blocked = true; loadError = "布局无法读取且无法备份。已暂停保存，请先检查本地文件：\(self.storageURL.path)" }
            }
        }
        let initial = loaded ?? Self.makeDefaultArchive()
        archive = initial
        selectedID = initial.activeCustomID ?? initial.profiles.first?.id
        errorMessage = loadError
        persistenceBlocked = blocked
        if loaded == nil && !blocked { persist() }
    }

    private static func makeDefaultArchive() -> DockArchive {
        func app(_ title: String, _ paths: [String]) -> DockItem? {
            guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
            return DockItem(kind: .app, title: title, target: path)
        }
        let apps = [
            app("Finder", ["/System/Library/CoreServices/Finder.app"]),
            app("Safari", ["/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]),
            app("备忘录", ["/System/Applications/Notes.app"]),
            app("日历", ["/System/Applications/Calendar.app"])
        ].compactMap { $0 }
        let daily = DockProfile(name: "日常", color: "8B7BF4", items: apps + [DockItem(kind: .spacer), DockItem(kind: .widget, title: "时钟", widget: .clock), DockItem(kind: .widget, title: "便签", widget: .note)])
        let focus = DockProfile(name: "专注", color: "5EAF97", items: apps.prefix(2).map { var copy = $0; copy.id = UUID(); return copy } + [DockItem(kind: .spacer), DockItem(kind: .widget, title: "专注计时", widget: .focus), DockItem(kind: .widget, title: "饮水记录", widget: .hydration)])
        var profiles = [daily, focus]
        if let native = try? NativeDockService().captureProfile(name: "macOS 当前布局") { profiles.append(native) }
        return DockArchive(profiles: profiles, activeCustomID: daily.id)
    }

    private func persist() {
        guard !persistenceBlocked else { return }
        do {
            _ = try archive.validated()
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(archive).write(to: storageURL, options: .atomic)
        } catch { errorMessage = "无法保存布局：\(error.localizedDescription)" }
    }

    func updateProfile(_ id: UUID, _ mutate: (inout DockProfile) -> Void) {
        guard let index = archive.profiles.firstIndex(where: { $0.id == id }) else { return }
        var profile = archive.profiles[index]; mutate(&profile)
        archive.profiles[index] = profile
    }
    func updateItem(_ item: DockItem, profileID: UUID) {
        updateProfile(profileID) { profile in
            if let i = profile.items.firstIndex(where: { $0.id == item.id }) { profile.items[i] = item }
        }
    }
    func addItems(_ items: [DockItem], to id: UUID? = nil) {
        guard let id = id ?? selectedID, let profile = profiles.first(where: { $0.id == id }) else { return }
        let allowed = items.filter { profile.kind == .custom || $0.kind == .app || $0.kind == .spacer }
        updateProfile(id) { $0.items.append(contentsOf: allowed) }
    }
    func addWidget(_ kind: WidgetKind) {
        guard selected?.kind == .custom else { return }
        addItems([DockItem(kind: .widget, title: kind.title, widget: kind)])
        widgetLibraryPresented = false
    }
    func createProfile(kind: ProfileKind) {
        let profile = DockProfile(name: kind == .custom ? "新布局" : "新的 macOS 布局", kind: kind)
        archive.profiles.append(profile); selectedID = profile.id
    }
    func captureNative() {
        do {
            let profile = try nativeService.captureProfile(name: "macOS 布局 \(profiles.filter { $0.kind == .native }.count + 1)")
            archive.profiles.append(profile); selectedID = profile.id
            notice = "已保存当前系统 Dock，未修改系统设置。"
        } catch { errorMessage = error.localizedDescription }
    }
    func duplicate(_ profile: DockProfile) {
        var copy = profile; copy.id = UUID(); copy.name += " 副本"
        copy.shortcut = nil
        copy.items = copy.items.map(Self.independentCopy)
        archive.profiles.append(copy); selectedID = copy.id
    }
    func deleteProfile(_ id: UUID) {
        guard archive.profiles.count > 1 else { return }
        guard !applyingNative || profiles.first(where: { $0.id == id })?.kind != .native else { return }
        for item in profiles.first(where: { $0.id == id })?.items ?? [] { LocalWidgetNotifications.shared.cancelAll(id: item.id) }
        var updated = archive
        updated.profiles.removeAll { $0.id == id }
        if updated.activeCustomID == id { updated.activeCustomID = updated.profiles.first { $0.kind == .custom }?.id }
        if updated.activeNativeID == id { updated.activeNativeID = nil }
        archive = updated
        if selectedID == id { selectedID = updated.profiles.first?.id }
    }
    func activate(_ profile: DockProfile) {
        if profile.kind == .custom { applyCustom(profile) }
        else { Task { do { try await activateAndWait(profile) } catch { errorMessage = error.localizedDescription } } }
    }
    private func applyCustom(_ profile: DockProfile) {
        guard profiles.contains(where: { $0.id == profile.id && $0.kind == .custom }) else { return }
        var updated = archive
        updated.activeCustomID = profile.id; updated.settings.showCustomDock = true
        if updated.settings.mode == .nativeOnly { updated.settings.mode = .both }
        archive = updated
        notice = "已切换到「\(profile.name)」。"
    }
    func activateAndWait(_ profile: DockProfile) async throws {
        guard let saved = profiles.first(where: { $0.id == profile.id }) else { throw ArchiveError.invalidProfiles }
        if saved.kind == .custom {
            applyCustom(saved)
        } else {
            pendingNativeOperations += 1; applyingNative = true
            defer { pendingNativeOperations -= 1; applyingNative = pendingNativeOperations > 0; lastNativeChange = Date() }
            try await nativeService.apply(saved, smooth: settings.smoothNativeSwitch)
            archive.activeNativeID = profiles.contains(where: { $0.id == saved.id }) ? saved.id : nil
            notice = "系统 Dock 已切换到「\(saved.name)」。"
        }
    }
    func restoreNative() {
        pendingNativeOperations += 1; applyingNative = true
        Task {
            defer { pendingNativeOperations -= 1; applyingNative = pendingNativeOperations > 0; lastNativeChange = Date() }
            do { try await nativeService.restoreLastBackup(); archive.activeNativeID = nil; notice = "已恢复上次切换前的系统 Dock。" }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func startNativeObservation() {
        nativeWatchTimer?.invalidate()
        nativeWatchTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.saveNativeChangesIfNeeded() }
        }
        nativeWatchTimer?.tolerance = 1
    }
    func stopNativeObservation() { nativeWatchTimer?.invalidate(); nativeWatchTimer = nil }
    func saveNativeChangesIfNeeded() {
        guard settings.autoSaveNativeChanges, !applyingNative, Date().timeIntervalSince(lastNativeChange) > 3,
              let id = archive.activeNativeID, let profile = profiles.first(where: { $0.id == id }),
              let current = try? nativeService.captureProfile(name: profile.name) else { return }
        // IDs in a capture are fresh; compare serialized native tiles/order instead.
        let old = try? NativeDockService.tiles(for: profile.items)
        let new = try? NativeDockService.tiles(for: current.items)
        guard let old, let new, !NSArray(array: old).isEqual(to: new) else { return }
        updateProfile(id) { $0.items = current.items }
        notice = "已自动保存 macOS Dock 的固定应用变化。"
    }
    static func independentCopy(_ original: DockItem) -> DockItem {
        var copy = original; copy.id = UUID()
        // Notification requests are tied to item identity and are explicitly enabled per copy.
        for key in ["alarmEnabled", "waterReminder", "timerNotification"] where copy.configuration[key] != nil { copy.configuration[key] = "false" }
        return copy
    }
    func duplicateItem(_ item: DockItem, in profileID: UUID) { addItems([Self.independentCopy(item)], to: profileID) }
    func removeItems(_ ids: Set<UUID>, from profileID: UUID) {
        for id in ids { LocalWidgetNotifications.shared.cancelAll(id: id) }
        updateProfile(profileID) { $0.items.removeAll { ids.contains($0.id) } }
    }
    func moveItems(_ ids: Set<UUID>, to targetID: UUID?, in profileID: UUID) {
        updateProfile(profileID) { profile in
            guard targetID.map({ !ids.contains($0) }) ?? true else { return }
            let moved = profile.items.filter { ids.contains($0.id) }
            guard !moved.isEmpty else { return }
            profile.items.removeAll { ids.contains($0.id) }
            let insertion = targetID.flatMap { target in profile.items.firstIndex { $0.id == target } } ?? profile.items.count
            profile.items.insert(contentsOf: moved, at: insertion)
        }
    }
    func cycleCustom(direction: Int) {
        let options = profiles.filter { $0.kind == .custom }
        guard !options.isEmpty else { return }
        let current = options.firstIndex { $0.id == archive.activeCustomID } ?? 0
        activate(options[(current + direction + options.count) % options.count])
    }
    func moveItem(_ itemID: UUID, before targetID: UUID, in profileID: UUID) {
        updateProfile(profileID) { profile in
            guard itemID != targetID, let from = profile.items.firstIndex(where: { $0.id == itemID }), let to = profile.items.firstIndex(where: { $0.id == targetID }) else { return }
            let item = profile.items.remove(at: from)
            profile.items.insert(item, at: to)
        }
    }
    func exportArchive() {
        let panel = NSSavePanel(); panel.title = "导出 Dock 布局"; panel.nameFieldStringValue = "OpenDock-layouts.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(archive).write(to: url, options: .atomic)
            notice = "布局已导出。"
        } catch { errorMessage = error.localizedDescription }
    }
    func importArchive() {
        let panel = NSOpenPanel(); panel.title = "导入 Dock 布局"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 10_000_000 else { throw ArchiveError.invalidProfiles }
            let incoming = try JSONDecoder().decode(DockArchive.self, from: data)
            archive = try archive.mergingProfiles(from: incoming)
            notice = "已导入布局，原有布局已保留。"
        } catch { errorMessage = "导入失败：\(error.localizedDescription)" }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            archive.settings.launchAtLogin = enabled
        } catch { errorMessage = "登录启动设置失败：\(error.localizedDescription)" }
    }
    func handleURL(_ url: URL) {
        guard url.scheme == "opendock", url.host == "profile" else { return }
        let identifier = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let profile = profiles.first(where: { $0.id.uuidString.caseInsensitiveCompare(identifier) == .orderedSame || $0.name == identifier }) else { errorMessage = "找不到 URL 指定的布局。"; return }
        // URL automations are deliberately limited to custom profiles: native writes require an in-app action.
        guard profile.kind == .custom else { errorMessage = "系统 Dock 的切换请在 OpenDock 内操作。"; return }
        activate(profile)
    }
}
