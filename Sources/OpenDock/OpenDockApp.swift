import SwiftUI
import AppKit
import Combine

@main
enum OpenDockBootstrap {
    @MainActor static func main() {
        if IntegrationStatusBridge.runIfRequested() { exit(0) }
        OpenDockApp.main()
    }
}

struct OpenDockApp: App {
    @NSApplicationDelegateAdaptor(OpenDockDelegate.self) private var delegate
    @StateObject private var store = AppStore.shared
    var body: some Scene {
        Window("OpenDock", id: "manager") {
            ManagerWindowContent(delegate: delegate).environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { Button("新建自定义布局") { store.createProfile(kind: .custom) }.keyboardShortcut("n") }
            CommandGroup(after: .importExport) { Button("导入布局…") { store.importArchive() }; Button("导出布局…") { store.exportArchive() }.keyboardShortcut("e", modifiers: [.command, .shift]) }
            CommandGroup(replacing: .appInfo) { Button("关于 OpenDock") { store.requestedPage = "about"; delegate.showManager() } }
        }
        MenuBarExtra { DockMenu().environmentObject(store) } label: {
            Label(store.settings.showActiveNameInMenuBar ? (store.settings.mode == .nativeOnly ? store.profiles.first { $0.id == store.archive.activeNativeID }?.name : store.activeCustom?.name) ?? "OpenDock" : "OpenDock", systemImage: "dock.rectangle")
        }
    }
}

struct ManagerWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    let delegate: OpenDockDelegate
    @EnvironmentObject private var store: AppStore
    var body: some View {
        ManagerView().sheet(isPresented: $store.tourPresented) { WalkthroughView().environmentObject(store) }.onAppear {
            let action = openWindow
            delegate.managerOpener = { action(id: "manager") }
            if !store.settings.hasCompletedTour { store.tourPresented = true }
        }
    }
}

struct DockMenu: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("OpenDock")
        ForEach(store.profiles.filter { $0.kind == .custom }) { profile in
            Button { store.activate(profile) } label: { Label(profile.name, systemImage: store.archive.activeCustomID == profile.id ? "checkmark.circle.fill" : "circle") }
        }
        if store.profiles.contains(where: { $0.kind == .native }) {
            Divider(); Text("macOS Dock")
            ForEach(store.profiles.filter { $0.kind == .native }) { profile in
                Button { store.activate(profile) } label: { Label(profile.name, systemImage: store.archive.activeNativeID == profile.id ? "checkmark.circle.fill" : "circle") }
            }
        }
        Divider()
        Button("管理 Dock…") { openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut(",")
        Button(store.settings.showCustomDock ? "隐藏自定义 Dock" : "显示自定义 Dock") { store.settings.showCustomDock.toggle() }
        Button("外观与设置…") { store.settingsPresented = true; openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("退出 OpenDock") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class OpenDockDelegate: NSObject, NSApplicationDelegate {
    var managerOpener: (() -> Void)?
    private var dockController: DockPanelController?
    private let hotkeys = GlobalHotkeyService()
    private var cancellables = Set<AnyCancellable>()
    private var terminating = false
    private var recordingProfileID: UUID?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.arguments.contains("--ui-test") {
            if ProcessInfo.processInfo.arguments.contains("--ui-test-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            else if ProcessInfo.processInfo.arguments.contains("--ui-test-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        }
        let store = AppStore.shared
        dockController = DockPanelController(store: store, openManager: { [weak self] in self?.showManager() })
        store.$archive.map { $0.profiles.map { profile in var copy = profile; copy.items = []; return copy } }.removeDuplicates().sink { [weak self] profiles in
            self?.configureHotkeys(profiles)
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .opendockShortcutRecordingChanged).receive(on: RunLoop.main).sink { [weak self] notification in
            guard let self, let id = notification.userInfo?["profileID"] as? UUID, let recording = notification.userInfo?["recording"] as? Bool else { return }
            if recording { self.recordingProfileID = id }
            else if self.recordingProfileID == id { self.recordingProfileID = nil }
            self.configureHotkeys(AppStore.shared.profiles)
        }.store(in: &cancellables)
        store.$archive.map(\.settings).removeDuplicates().sink { settings in
            let testing = ProcessInfo.processInfo.arguments.contains("--smoke-test") || ProcessInfo.processInfo.arguments.contains("--ui-test")
            if !testing { NativeDockModeService.shared.update(mode: settings.mode) }
            if WindowMonitor.shared.enabled != settings.showMinimizedWindows { WindowMonitor.shared.setEnabled(settings.showMinimizedWindows) }
            if WindowMonitor.shared.badgesEnabled != settings.showBadges { WindowMonitor.shared.setBadgesEnabled(settings.showBadges) }
            if settings.autoSaveNativeChanges && !testing { store.startNativeObservation() } else { store.stopNativeObservation() }
        }.store(in: &cancellables)
        store.$archive.map { $0.settings.automaticUpdateCheck }.removeDuplicates().sink { enabled in UpdateService.shared.setAutomatic(enabled) }.store(in: &cancellables)
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let count = NSApp.windows.filter { $0.isVisible }.count
                print("OpenDock smoke: profiles=\(store.profiles.count), widgets=\(WidgetKind.allCases.count), visibleWindows=\(count)")
                NSApp.terminate(nil)
            }
        }
    }
    private func configureHotkeys(_ profiles: [DockProfile]) {
        guard recordingProfileID == nil else { hotkeys.unregister(); return }
        hotkeys.register(profiles: profiles) { index in
            guard profiles.indices.contains(index), let profile = AppStore.shared.profiles.first(where: { $0.id == profiles[index].id }) else { return }
            AppStore.shared.activate(profile)
        }
        let unavailable = hotkeys.unavailableIndices.filter { profiles.indices.contains($0) }
        if !unavailable.isEmpty { AppStore.shared.notice = "部分快捷键被占用：" + unavailable.map { profiles[$0].name }.joined(separator: "、") + "。请在设置中重新录制。" }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") || ProcessInfo.processInfo.arguments.contains("--ui-test") { return .terminateNow }
        if terminating { return .terminateNow }
        dockController?.prepareForTermination()
        guard NativeDockModeService.shared.hasRecoverySnapshot || AppStore.shared.applyingNative else { return .terminateNow }
        terminating = true
        Task {
            do { try await NativeDockModeService.shared.restoreForTermination(); sender.reply(toApplicationShouldTerminate: true) }
            catch { terminating = false; AppStore.shared.errorMessage = "退出前恢复系统 Dock 失败：\(error.localizedDescription)"; showManager(); sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppStore.shared.handleURL(url) }
    }
    func showManager() {
        managerOpener?()
        if let window = NSApp.windows.first(where: { $0.title == "OpenDock" && !($0 is NSPanel) }) { window.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
}
