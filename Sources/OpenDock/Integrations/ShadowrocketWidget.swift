import AppKit
import Combine
import SwiftUI

@MainActor private final class ShadowrocketWidgetRuntime: ObservableObject {
    @Published private(set) var snapshot = ShadowrocketStatusSnapshot()
    @Published var error: String?
    func refresh() { snapshot = ShadowrocketStatusReader.read() }

    func openClient() {
        guard let url = snapshot.applicationURL, ShadowrocketStatusReader.verifiedApplication(at: url) else {
            error = "无法定位 Shadowrocket 的应用程序路径。可在 Finder 中打开客户端，再刷新组件。"; refresh(); return
        }
        error = nil
        // This runs only after an explicit button click. Launching the client
        // does not request a connection or change the user's proxy settings.
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in
                if error != nil { self?.error = "无法打开 Shadowrocket，请在 Finder 中检查客户端。" }
                self?.refresh()
            }
        }
    }
}

struct ShadowrocketWidgetTile: View {
    let item: DockItem
    var compact: Bool = false
    let onUpdate: (DockItem) -> Void
    @StateObject private var runtime = ShadowrocketWidgetRuntime()
    @ObservedObject private var coordinator = WidgetPopoverCoordinator.shared
    @State private var presented = false
    @State private var config: [String: String]
    @State private var titleDraft: String

    init(item: DockItem, compact: Bool = false, onUpdate: @escaping (DockItem) -> Void) {
        self.item = item; self.compact = compact; self.onUpdate = onUpdate
        _config = State(initialValue: item.configuration)
        _titleDraft = State(initialValue: item.configuration["title"] ?? "Shadowrocket")
    }

    private var title: String { let value = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? "Shadowrocket" : String(value.prefix(80)) }
    private var showProxyAsSummary: Bool { config["shadowrocketDisplay"] == "proxy" }
    private var summary: String { showProxyAsSummary ? runtime.snapshot.proxies.summary : runtime.snapshot.clientSummary }
    private var subtitle: String { showProxyAsSummary ? runtime.snapshot.clientSummary : runtime.snapshot.proxies.summary }
    private var setup: Bool { config["widgetSetupOpen"] == "true" }
    private var accent: Color { DockTheme.accent }

    var body: some View {
        Button { NSApp.activate(ignoringOtherApps: true); presented.toggle() } label: {
            HStack(spacing: 9) {
                clientIcon.frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.65)
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 11).frame(width: compact ? 132 : 140, height: 58)
                .dockGlass(cornerRadius: 14, tint: accent.opacity(0.09), interactive: true)
        }.buttonStyle(.plain).help(title)
        .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue("\(summary)。\(runtime.snapshot.connectionSummary)。")
        .popover(isPresented: $presented, arrowEdge: compact ? .leading : .bottom) { popover }
        .onChange(of: presented) { open in
            if open { coordinator.activeID = item.id }
            else { saveTitleDraft(); if coordinator.activeID == item.id { coordinator.activeID = nil } }
        }
        .onChange(of: coordinator.activeID) { active in if active != item.id { presented = false } }
        .onChange(of: item.configuration) { value in if config != value { config = value; titleDraft = value["title"] ?? "Shadowrocket" } }
        .onChange(of: titleDraft) { _ in saveTitleDraft() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in runtime.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in runtime.refresh() }
        .task(id: config["autoRefresh"] ?? "true") {
            runtime.refresh()
            guard config["autoRefresh"] != "false" else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }; runtime.refresh()
            }
        }
        .contextMenu {
            Button("打开 Shadowrocket") { runtime.openClient() }.disabled(!runtime.snapshot.installed)
            Button("刷新状态") { runtime.refresh() }
            Button("自定义小组件…") { set("widgetSetupOpen", "true"); NSApp.activate(ignoringOtherApps: true); presented = true }
        }
        .onDisappear { saveTitleDraft(); if coordinator.activeID == item.id { coordinator.activeID = nil } }
    }

    @ViewBuilder private var clientIcon: some View {
        if let url = runtime.snapshot.applicationURL { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit() }
        else { Image(systemName: "paperplane").font(.system(size: 21)).foregroundStyle(accent) }
    }

    private var popover: some View {
        VStack(spacing: 12) {
            WidgetPopoverHeader(title: title, symbol: "network", tint: accent, subtitle: "客户端状态与系统默认代理", onClose: close) {
                WidgetPopoverIconButton(symbol: "arrow.clockwise", label: "刷新状态") { runtime.refresh() }
                WidgetPopoverIconButton(symbol: "slider.horizontal.3", label: "显示选项") { set("widgetSetupOpen", String(!setup)) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) { clientIcon.frame(width: 36, height: 36); VStack(alignment: .leading, spacing: 3) { Text("Shadowrocket").font(.headline); Text(runtime.snapshot.clientSummary).font(.caption).foregroundStyle(.secondary) }; Spacer() }
                        if let version = runtime.snapshot.version { statusRow("客户端版本", value: version) }
                        statusRow("连接状态", value: runtime.snapshot.connectionSummary)
                        Text("客户端运行状态不代表隧道状态。节点、流量与延迟请在 Shadowrocket 中查看。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if runtime.snapshot.installed { Button("打开客户端") { close(); runtime.openClient() }.buttonStyle(DockGlassButtonStyle(prominent: true)) }
                            else { Button("查看 App Store") { NSWorkspace.shared.open(ShadowrocketStatusReader.appStoreURL) }.buttonStyle(DockGlassButtonStyle(prominent: true)) }
                            Button("系统设置") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }.buttonStyle(DockGlassButtonStyle())
                        }
                    }.padding(14).dockCard(cornerRadius: 16)
                    proxySection
                    if let error = runtime.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if setup { displayOptions }
                    if let date = runtime.snapshot.sampledAt { Text("最后检查：\(date.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.secondary) }
                }.padding(.horizontal, 2).padding(.bottom, 2)
            }.frame(maxHeight: 470)
        }.padding(16).frame(width: 390).onExitCommand(perform: close)
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("系统默认代理").font(.headline)
            Label(runtime.snapshot.proxies.summary, systemImage: runtime.snapshot.proxies.isConfigured ? "network" : "circle.dashed").font(.callout)
            if config["shadowrocketShowEndpoints"] != "false" {
                ForEach(runtime.snapshot.proxies.endpoints) { endpoint in
                    VStack(alignment: .leading, spacing: 3) {
                        statusRow(endpoint.kind, value: endpoint.address)
                        if endpoint.isLoopback { Text("本机地址；所属客户端无法确认。").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            if runtime.snapshot.proxies.automaticConfiguration { Text("PAC 自动配置已启用；组件不获取或执行 PAC。").font(.caption).foregroundStyle(.secondary) }
            if runtime.snapshot.proxies.automaticDiscovery { Text("代理自动发现已启用。").font(.caption).foregroundStyle(.secondary) }
            if runtime.snapshot.proxies.hasUnknownFlags { Text("部分代理标记无法解析。").font(.caption).foregroundStyle(.secondary) }
            Text("这些设置可能来自其他软件。启用系统代理不能证明 Shadowrocket 已连接；未启用也不排除 VPN 隧道或应用单独使用代理。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).dockCard(cornerRadius: 16)
    }

    private var displayOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("显示选项").font(.headline)
            TextField("组件标题", text: $titleDraft).textFieldStyle(.roundedBorder)
            Picker("主要显示", selection: Binding(get: { showProxyAsSummary ? "proxy" : "client" }, set: { set("shadowrocketDisplay", $0) })) {
                Text("客户端状态").tag("client"); Text("系统代理摘要").tag("proxy")
            }
            Toggle("显示代理地址", isOn: Binding(get: { config["shadowrocketShowEndpoints"] != "false" }, set: { set("shadowrocketShowEndpoints", String($0)) }))
            Toggle("自动刷新状态（15 秒）", isOn: Binding(get: { config["autoRefresh"] != "false" }, set: { set("autoRefresh", String($0)) }))
            Text("显示选项自动保存，关闭面板会保留标题草稿。代理地址仅保存在内存中。").font(.caption).foregroundStyle(.secondary)
        }.padding(14).dockCard(cornerRadius: 16)
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 10); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.caption)
    }
    private func close() { saveTitleDraft(); presented = false; if coordinator.activeID == item.id { coordinator.activeID = nil } }
    private func saveTitleDraft() { set("title", String(titleDraft.prefix(80))) }
    private func set(_ key: String, _ value: String) {
        guard config[key] != value else { return }
        config[key] = value; var updated = item; updated.configuration = config; onUpdate(updated)
    }
}
