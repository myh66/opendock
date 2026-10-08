import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CustomDockView: View {
    @EnvironmentObject var store: AppStore
    let openManager: () -> Void
    @State private var running: [DockItem] = []
    @State private var dragging: UUID?
    private var vertical: Bool { store.settings.position != .bottom }
    private var runningExtras: [DockItem] {
        guard store.settings.showRunningApps else { return [] }
        let pinned = Set(store.activeCustom?.items.filter { $0.kind == .app }.map(\.target) ?? [])
        return Array(running.filter { !pinned.contains($0.target) }.prefix(12))
    }
    var body: some View {
        VStack(spacing: 5) {
            if let profile = store.activeCustom {
                ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                    if vertical { VStack(spacing: 8) { items(profile) }.frame(maxWidth: .infinity).padding(12) }
                    else { HStack(spacing: 8) { items(profile) }.padding(12) }
                }
                HStack(spacing: 5) { Circle().fill(Color(hex: profile.color)).frame(width: 4, height: 4); Text(profile.name).font(.system(size: 9, weight: .medium)).lineLimit(1); Button(action: openManager) { Image(systemName: "slider.horizontal.3").font(.system(size: 10)) }.buttonStyle(.plain).help("管理 Dock") }.foregroundStyle(.secondary).padding(.bottom, 8)
            } else { Button("创建 Dock", action: openManager).padding(20) }
        }
        .background {
            if store.settings.material == .dark { RoundedRectangle(cornerRadius: 21).fill(Color.black.opacity(0.8)) }
            else if store.settings.material == .clear { RoundedRectangle(cornerRadius: 21).fill(.ultraThinMaterial) }
            else { RoundedRectangle(cornerRadius: 21).fill(.regularMaterial) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(.white.opacity(0.3), lineWidth: 1))
        .preferredColorScheme(store.settings.material == .dark ? .dark : nil)
        .tint(DockTheme.accent)
        .contextMenu {
            Button("管理 Dock…", action: openManager)
            Menu("切换布局") { ForEach(store.profiles.filter { $0.kind == .custom }) { profile in Button(profile.name) { store.activate(profile) } } }
            Button("添加应用…") { if let id = store.activeCustom?.id { store.addItems(AppService.chooseItems(kind: .app), to: id) } }
            Button("添加组件…") { store.selectedID = store.archive.activeCustomID; store.widgetLibraryPresented = true; openManager() }
            Divider()
            Button("隐藏 Dock") { store.settings.showCustomDock = false }
        }
        .onAppear(perform: refreshRunning)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunning() }
    }
    @ViewBuilder private func items(_ profile: DockProfile) -> some View {
        ForEach(profile.items) { item in
            Group {
                if item.kind == .widget { WidgetTile(item: item, compact: vertical, onUpdate: { store.updateItem($0, profileID: profile.id) }) }
                else if item.kind == .spacer {
                    if vertical { Rectangle().fill(.secondary.opacity(0.2)).frame(width: 34, height: 1).padding(.vertical, item.configuration["size"] == "small" ? 2 : 6) }
                    else { Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1, height: 34).padding(.horizontal, item.configuration["size"] == "small" ? 2 : 6) }
                } else { DockLauncher(item: item, profileID: profile.id).environmentObject(store) }
            }
            .onDrag { dragging = item.id; return NSItemProvider(object: item.id.uuidString as NSString) }
            .onDrop(of: [.text], delegate: ItemReorderDelegate(itemID: item.id, profileID: profile.id, dragging: $dragging, store: store))
        }
        if !runningExtras.isEmpty {
            if vertical { Divider().frame(width: 34) } else { Divider().frame(height: 34) }
            ForEach(runningExtras) { item in DockLauncher(item: item, profileID: profile.id, pinned: false).environmentObject(store) }
        }
        if store.settings.showTrash { TrashTile(size: store.settings.iconSize) }
    }
    private func refreshRunning() { running = AppService.runningApps() }
}

struct DockLauncher: View {
    @EnvironmentObject var store: AppStore
    let item: DockItem
    let profileID: UUID
    var pinned = true
    @State private var hovered = false
    @State private var browse = false
    @State private var contents: [DockItem] = []
    var body: some View {
        Button {
            if item.kind == .appGroup { loadContents(); browse.toggle() }
            else if item.kind == .app { if !AppService.click(item, minimizeIfActive: store.settings.clickToMinimize) { store.errorMessage = store.settings.clickToMinimize && !AppService.accessibilityEnabled ? "最小化窗口需要辅助功能权限，请在设置中开启。" : "无法打开应用或操作当前窗口。请确认应用仍位于保存的位置。" } }
            else { AppService.open(item) }
        } label: {
            VStack(spacing: 3) {
                AppIconView(item: item, size: store.settings.iconSize).scaleEffect(hovered && store.settings.magnification && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.14 : 1)
                Circle().fill(AppService.runningApplication(for: item) != nil ? Color.primary.opacity(0.5) : .clear).frame(width: 4, height: 4)
            }.padding(3)
        }.buttonStyle(.plain).help(item.title)
        .onHover { value in withAnimation(.easeOut(duration: 0.12)) { hovered = value } }
        .popover(isPresented: $browse) { ScrollView { VStack(alignment: .leading, spacing: 9) { Text(item.title).font(.headline); if contents.isEmpty { Text("这里暂时没有可显示的项目。").foregroundStyle(.secondary) }; ForEach(contents) { child in Button { AppService.open(child); browse = false } label: { HStack { AppIconView(item: child, size: 24); Text(child.title).lineLimit(1); Spacer() } }.buttonStyle(.plain) } }.padding(18) }.frame(width: 300, height: min(CGFloat(contents.count * 38 + 70), 400)) }
        .contextMenu {
            Button("打开") { AppService.open(item) }
            if item.kind == .folder || item.kind == .appGroup { Button("浏览内容") { loadContents(); browse = true } }
            if item.kind == .app {
                let windows = AppService.applicationWindows(for: item)
                if !windows.isEmpty { Menu("窗口") { ForEach(windows) { window in Button((window.isMinimized ? "↗ " : "") + window.title) { AppService.activateWindow(window) } } } }
                Button("退出应用") { AppService.quit(item) }.disabled(AppService.runningApplication(for: item) == nil)
            }
            if item.kind != .appGroup && item.kind != .link { Button("在 Finder 中显示") { AppService.reveal(item) } }
            Divider()
            if pinned { Button("从 Dock 移除") { store.updateProfile(profileID) { $0.items.removeAll { $0.id == item.id } } } }
            else { Button("保留在 Dock 中") { var copy = item; copy.id = UUID(); store.addItems([copy], to: profileID) } }
        }
    }
    private func loadContents() {
        if item.kind == .appGroup {
            if let data = item.configuration["apps"]?.data(using: .utf8), let apps = try? JSONDecoder().decode([DockItem].self, from: data) { contents = apps }
            else if let data = item.target.data(using: .utf8), let paths = try? JSONDecoder().decode([String].self, from: data) { contents = paths.map { DockItem(kind: .app, title: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent, target: $0) } }
        } else {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: item.target), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            contents = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(100).map { url in DockItem(kind: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? .folder : .file, title: url.lastPathComponent, target: url.path) }
        }
    }
}

struct TrashTile: View {
    var size: Double
    var body: some View {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")) } label: { Image(systemName: "trash").font(.system(size: size * 0.64, weight: .light)).frame(width: size, height: size).padding(3) }.buttonStyle(.plain).help("打开废纸篓")
    }
}
