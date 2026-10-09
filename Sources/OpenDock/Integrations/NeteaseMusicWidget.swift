import AppKit
import SwiftUI

@MainActor final class NeteaseMusicWidgetRuntime: ObservableObject {
    static let bundleIdentifier = "com.netease.163music"
    @Published var applicationURL: URL?
    @Published var isRunning = false
    @Published var opening = false
    @Published var launchError: String?
    func refresh() {
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == Self.bundleIdentifier && !$0.isTerminated }
        applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) ?? running?.bundleURL
        isRunning = running != nil
    }
    func open() {
        refresh()
        guard let applicationURL else { launchError = "未找到已安装的网易云音乐。"; return }
        opening = true; launchError = nil
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.opening = false; self.refresh()
                if failed { self.launchError = "网易云音乐未能打开，请从访达检查安装。" }
            }
        }
    }
}

struct NeteaseMusicWidgetTile: View {
    let item: DockItem
    var compact: Bool = false
    let onUpdate: (DockItem) -> Void
    @StateObject private var runtime = NeteaseMusicWidgetRuntime()
    @ObservedObject private var coordinator = WidgetPopoverCoordinator.shared
    @State private var config: [String: String]
    @State private var presented = false
    @State private var status: String?
    @State private var removed: (NeteaseMusicBookmark, Int)?
    private let tint = Color(red: 0.83, green: 0.25, blue: 0.29)
    init(item: DockItem, compact: Bool = false, onUpdate: @escaping (DockItem) -> Void) {
        self.item = item; self.compact = compact; self.onUpdate = onUpdate
        _config = State(initialValue: item.configuration)
    }
    private var title: String { item.title.isEmpty ? "网易云音乐" : item.title }
    private var bookmarks: [NeteaseMusicBookmark] { NeteaseMusicBookmarks.decode(config["neteaseBookmarks"]) }
    private var clientStatus: String { runtime.isRunning ? "客户端正在运行" : runtime.applicationURL != nil ? "客户端已安装，尚未运行" : "未找到已安装的客户端" }
    var body: some View {
        Button { NSApp.activate(ignoringOtherApps: true); presented.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "music.note.list").font(.system(size: 20)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(runtime.isRunning ? "App 运行中 · \(bookmarks.count) 个入口" : bookmarks.isEmpty ? "打开 App · 收藏入口" : "\(bookmarks.count) 个收藏入口").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).frame(width: compact ? 132 : 140, height: 58)
                .dockGlass(cornerRadius: 14, tint: tint.opacity(0.09), interactive: true)
        }.buttonStyle(.plain).help(title).accessibilityLabel(title + "，启动与收藏入口")
            .popover(isPresented: $presented, arrowEdge: compact ? .leading : .bottom) { popover }
            .onChange(of: presented) { opened in
                if opened { coordinator.activeID = item.id }
                else if coordinator.activeID == item.id { coordinator.activeID = nil }
            }
            .onChange(of: coordinator.activeID) { if $0 != item.id { presented = false } }
            .onChange(of: item.configuration) { if config != $0 { config = $0 } }
            .onAppear { runtime.refresh() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { refreshForApplication($0) }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { refreshForApplication($0) }
            .onDisappear { if coordinator.activeID == item.id { coordinator.activeID = nil } }
            .contextMenu {
                Button("查看收藏入口…") { presented = true }
                Button(runtime.isRunning ? "打开网易云音乐" : "启动网易云音乐") { runtime.open() }.disabled(runtime.applicationURL == nil || runtime.opening)
                Button("刷新客户端状态") { runtime.refresh() }
            }
    }
    private var popover: some View {
        VStack(spacing: 12) {
            WidgetPopoverHeader(title: title, symbol: "music.note.list", tint: tint, subtitle: "启动与官方收藏链接", onClose: { presented = false }) {
                WidgetPopoverIconButton(symbol: "arrow.clockwise", label: "刷新客户端安装与运行状态") { runtime.refresh() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    launchControls
                    bookmarkList
                    addControls
                    if let error = runtime.launchError { Text(error).font(.caption).foregroundStyle(.orange) }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).dockCard(cornerRadius: 16)
            }
        }.padding(14).frame(width: 440, height: bookmarks.isEmpty ? 460 : 540).dockCard(cornerRadius: 22)
            .buttonStyle(DockGlassButtonStyle()).onExitCommand { presented = false }
            .background { Button("关闭小组件") { presented = false }.keyboardShortcut("w", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true) }
    }
    private var launchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(clientStatus, systemImage: runtime.isRunning ? "checkmark.circle" : runtime.applicationURL != nil ? "app.badge" : "questionmark.app")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(runtime.opening ? "正在打开…" : runtime.isRunning ? "打开网易云音乐" : "启动网易云音乐") { runtime.open() }
                    .buttonStyle(DockGlassButtonStyle(prominent: true)).disabled(runtime.applicationURL == nil || runtime.opening)
                Link("网页版", destination: URL(string: "https://music.163.com/")!)
            }
            if runtime.applicationURL == nil { Text("可通过网页版打开收藏。").font(.caption).foregroundStyle(.secondary) }
            Text("运行状态只表示客户端进程存在，不表示正在播放。没有已验证的公开曲目/播放控制接口，组件不会读取账号、当前曲目或控制播放。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var bookmarkList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("收藏入口（\(bookmarks.count)/50）").font(.headline)
                Spacer()
                if removed != nil { Button("撤销移除") { undo() }.font(.caption) }
            }
            if bookmarks.isEmpty { Text("添加喜欢的歌单、歌曲、专辑或艺人链接。名称和链接只保存在本机 Dock 配置。").font(.callout).foregroundStyle(.secondary) }
            ForEach(bookmarks) { entry in bookmarkRow(entry) }
        }
    }
    private func bookmarkRow(_ entry: NeteaseMusicBookmark) -> some View {
        let parsed = try? NeteaseMusicPublicLink(entry.link)
        return HStack(spacing: 10) {
            Image(systemName: parsed?.kind.symbol ?? "music.note.list").foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                if let parsed { Link(entry.title, destination: parsed.url).font(.callout).lineLimit(2) }
                Text(parsed.map { "\($0.kind.title) · \($0.resourceID)" } ?? "无效链接").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { remove(entry) } label: { Image(systemName: "trash").frame(width: 16, height: 16) }
                .help("移除「\(entry.title)」").accessibilityLabel("移除「\(entry.title)」")
        }.padding(12).dockCard(cornerRadius: 12)
    }
    private var addControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加收藏").font(.headline)
            TextField("入口名称", text: draft("neteaseNameDraft", limit: 120)).textFieldStyle(.roundedBorder)
            TextField("https://music.163.com/#/playlist?id=…", text: draft("neteaseLinkDraft", limit: 2048))
                .textFieldStyle(.roundedBorder).onSubmit { add() }.accessibilityLabel("网易云官方收藏链接")
            Button("保存收藏入口") { add() }.buttonStyle(DockGlassButtonStyle(prominent: true))
                .disabled((config["neteaseNameDraft"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (config["neteaseLinkDraft"] ?? "").isEmpty)
            Text("只接受 music.163.com 的 HTTPS 官方链接，不接受 orpheus 控制指令。关闭后保留未保存的输入。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func refreshForApplication(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == NeteaseMusicWidgetRuntime.bundleIdentifier else { return }
        runtime.refresh()
    }
    private func add() {
        do {
            let entries = try NeteaseMusicBookmarks.adding(title: config["neteaseNameDraft"] ?? "", link: config["neteaseLinkDraft"] ?? "", to: bookmarks)
            save(entries); status = "已保存收藏入口。"; set("neteaseNameDraft", ""); set("neteaseLinkDraft", "")
        } catch { status = error.localizedDescription }
    }
    private func remove(_ entry: NeteaseMusicBookmark) {
        var list = bookmarks; guard let index = list.firstIndex(where: { $0.id == entry.id }) else { return }
        removed = (list.remove(at: index), index); save(list); status = "已移除，可撤销。"
    }
    private func undo() {
        guard let removed else { return }
        var list = bookmarks
        guard list.count < NeteaseMusicBookmarks.maximum, !list.contains(where: { $0.id == removed.0.id || $0.link == removed.0.link }) else { self.removed = nil; return }
        list.insert(removed.0, at: min(removed.1, list.count)); save(list); self.removed = nil; status = "已恢复入口。"
    }
    private func save(_ entries: [NeteaseMusicBookmark]) { if let value = NeteaseMusicBookmarks.encode(entries) { set("neteaseBookmarks", value) } }
    private func draft(_ key: String, limit: Int) -> Binding<String> { Binding(get: { config[key] ?? "" }, set: { set(key, String($0.prefix(limit))) }) }
    private func set(_ key: String, _ value: String) {
        guard config[key] != value else { return }
        config[key] = value; var updated = item; updated.configuration = config; onUpdate(updated)
    }
}
