import SwiftUI
import AppKit
import Combine

@main
struct OpenDockApp: App {
    @NSApplicationDelegateAdaptor(OpenDockDelegate.self) private var delegate
    @StateObject private var store = AppStore.shared
    var body: some Scene {
        WindowGroup("OpenDock", id: "manager") {
            ManagerWindowContent(delegate: delegate).environmentObject(store).onOpenURL { store.handleURL($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { Button("新建自定义布局") { store.createProfile(kind: .custom) }.keyboardShortcut("n") }
            CommandGroup(after: .importExport) { Button("导入布局…") { store.importArchive() }; Button("导出布局…") { store.exportArchive() }.keyboardShortcut("e", modifiers: [.command, .shift]) }
            CommandGroup(replacing: .appInfo) { Button("关于 OpenDock") { delegate.showManager() } }
        }
        MenuBarExtra("OpenDock", systemImage: "dock.rectangle") { DockMenu().environmentObject(store) }
    }
}

struct ManagerWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    let delegate: OpenDockDelegate
    var body: some View {
        ManagerView().onAppear {
            let action = openWindow
            delegate.managerOpener = { action(id: "manager") }
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
                Button(profile.name) { store.selectedID = profile.id; store.requestedPage = "docks"; openWindow(id: "manager"); NSApp.activate(ignoringOtherApps: true) }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let store = AppStore.shared
        dockController = DockPanelController(store: store, openManager: { [weak self] in self?.showManager() })
        store.$archive.map { $0.profiles.map(\.id) }.removeDuplicates().sink { [weak self] ids in
            self?.hotkeys.register(count: min(ids.count, 9)) { index in
                guard index >= 0, index < store.profiles.count else { return }
                let profile = store.profiles[index]
                if profile.kind == .custom { store.activate(profile) }
                else { store.selectedID = profile.id; store.requestedPage = "docks"; self?.showManager() }
            }
        }.store(in: &cancellables)
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let count = NSApp.windows.filter { $0.isVisible }.count
                print("OpenDock smoke: profiles=\(store.profiles.count), widgets=\(WidgetKind.allCases.count), visibleWindows=\(count)")
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func showManager() {
        managerOpener?()
        if let window = NSApp.windows.first(where: { $0.title == "OpenDock" && !($0 is NSPanel) }) { window.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
}
