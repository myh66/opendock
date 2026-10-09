import AppKit
import SwiftUI

@MainActor final class OllamaWidgetRuntime: ObservableObject {
    @Published var report: OllamaWidgetReport?
    @Published var busy = false
    @Published var error: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    func refresh(_ input: String) {
        let endpoint: OllamaWidgetEndpoint
        do { endpoint = try OllamaWidgetEndpoint(input) }
        catch { self.error = error.localizedDescription; return }
        cancel()
        if report?.endpoint != endpoint.url.absoluteString { report = nil }
        let token = UUID(); generation = token; busy = true; error = nil
        operation = Task { [weak self] in
            do {
                let report = try await OllamaWidgetHTTP.load(endpoint)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.report = report; self.busy = false; self.operation = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.busy = false; self.operation = nil
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { generation = UUID(); operation?.cancel(); operation = nil; busy = false }
    func disconnect() { cancel(); report = nil; error = nil }
    deinit { operation?.cancel() }
}

struct OllamaWidgetTile: View {
    let item: DockItem
    var compact: Bool = false
    let onUpdate: (DockItem) -> Void
    @StateObject private var runtime = OllamaWidgetRuntime()
    @ObservedObject private var coordinator = WidgetPopoverCoordinator.shared
    @State private var config: [String: String]
    @State private var endpointInput: String
    @State private var presented = false
    init(item: DockItem, compact: Bool = false, onUpdate: @escaping (DockItem) -> Void) {
        self.item = item; self.compact = compact; self.onUpdate = onUpdate
        _config = State(initialValue: OllamaWidgetEndpoint.sanitizedConfiguration(item.configuration))
        _endpointInput = State(initialValue: item.configuration["ollamaEndpointDraft"] ?? item.configuration["ollamaEndpoint"] ?? "http://127.0.0.1:11434")
    }
    private var storedDraft: String { config["ollamaEndpointDraft"] ?? config["ollamaEndpoint"] ?? "http://127.0.0.1:11434" }
    private var unsavedDraft: Bool { !OllamaWidgetEndpoint.draftCanPersist(endpointInput) }
    private var title: String { item.title.isEmpty ? "Ollama" : item.title }
    private var summary: String {
        if runtime.busy { return "正在读取…" }
        if let report = runtime.report { return "\(report.running.count) 内存中 · \(report.installed.count) 模型" }
        return "连接本机 Ollama"
    }
    var body: some View {
        Button { NSApp.activate(ignoringOtherApps: true); presented.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "server.rack").font(.system(size: 20)).foregroundStyle(DockTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(runtime.report.map { "v\($0.version) · 采样快照" } ?? "只读模型与内存状态").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).frame(width: compact ? 132 : 140, height: 58)
                .dockGlass(cornerRadius: 14, tint: DockTheme.accent.opacity(0.09), interactive: true)
        }.buttonStyle(.plain).help(title).accessibilityLabel(title + "，" + summary)
            .popover(isPresented: $presented, arrowEdge: compact ? .leading : .bottom) { popover }
            .onChange(of: presented) { opened in
                if opened { coordinator.activeID = item.id }
                else { runtime.cancel(); if coordinator.activeID == item.id { coordinator.activeID = nil } }
            }
            .onChange(of: coordinator.activeID) { if $0 != item.id { presented = false } }
            .onChange(of: item.configuration) { synchronize($0) }
            .onAppear { if config != item.configuration { publishConfiguration() } }
            .onDisappear { runtime.cancel(); if coordinator.activeID == item.id { coordinator.activeID = nil } }
            .contextMenu { Button("查看 Ollama…") { presented = true }; Button("刷新本机状态") { connect() } }
    }
    private var popover: some View {
        VStack(spacing: 12) {
            WidgetPopoverHeader(title: title, symbol: "server.rack", tint: DockTheme.accent, subtitle: "本机模型 · 只读", onClose: { presented = false }) {
                WidgetPopoverIconButton(symbol: "arrow.clockwise", label: "手动刷新本机状态") { connect() }.disabled(runtime.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionControls
                    if let report = runtime.report { reportView(report) }
                    else if !runtime.busy {
                        Text("点击连接后读取本机服务。这里不会生成内容、加载或下载模型。").font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = runtime.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    Link("Ollama 官方 API", destination: URL(string: "https://docs.ollama.com/api/tags")!).font(.caption)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).dockCard(cornerRadius: 16)
            }
        }.padding(14).frame(width: 440, height: runtime.report != nil ? 560 : runtime.error != nil || unsavedDraft ? 400 : 340).dockCard(cornerRadius: 22)
            .buttonStyle(DockGlassButtonStyle()).onExitCommand { presented = false }
            .background { Button("关闭小组件") { presented = false }.keyboardShortcut("w", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true) }
    }
    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("http://127.0.0.1:11434", text: Binding(get: { endpointInput }, set: updateDraft))
                .textFieldStyle(.roundedBorder).onSubmit { connect() }.accessibilityLabel("Ollama 本机服务地址")
            if unsavedDraft {
                Text("当前草稿可能含敏感内容或无效地址，仅保留在内存，未保存。请移除账号、查询参数与片段后连接。").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(runtime.busy ? "正在读取…" : "连接并读取") { connect() }.buttonStyle(DockGlassButtonStyle(prominent: true)).disabled(runtime.busy)
                if runtime.busy { ProgressView().controlSize(.small); Button("取消") { runtime.cancel() } }
                if runtime.report != nil { Button("清除读数") { runtime.disconnect() } }
            }
            Text("仅支持 127.0.0.1、localhost、[::1]。关闭弹窗会取消未完成请求；重新打开不会自动访问服务。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func reportView(_ report: OllamaWidgetReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Ollama \(report.version)").font(.headline); Spacer(); Text("只读").font(.caption).foregroundStyle(.secondary) }
            Text("读数来源：" + report.endpoint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if endpointInput.trimmingCharacters(in: .whitespacesAndNewlines) != report.endpoint {
                Text("地址输入尚未重新读取；以下仍是此来源的旧快照。").font(.caption).foregroundStyle(.secondary)
            }
            Text("采样于 " + report.fetchedAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
            Text("状态与释放时间均为此时的快照；\(report.isStale() ? "已超过 1 分钟，请刷新。" : "点击刷新获取新的状态。")").font(.caption).foregroundStyle(.secondary)
            modelSection("内存中的模型", models: report.running, running: true, stamp: report.fetchedAt)
            modelSection("已安装模型", models: report.installed, running: false, stamp: report.fetchedAt)
        }
    }
    private func modelSection(_ title: String, models: [OllamaWidgetModel], running: Bool, stamp: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title)（\(models.count)）").font(.headline)
            if models.isEmpty { Text(running ? "采样时没有模型驻留内存。" : "本机服务未列出已安装模型。").font(.caption).foregroundStyle(.secondary) }
            ForEach(models) { model in OllamaWidgetModelRow(model: model, running: running, stamp: stamp) }
        }
    }
    private func connect() {
        do { let endpoint = try OllamaWidgetEndpoint(endpointInput); set("ollamaEndpoint", endpoint.url.absoluteString); runtime.refresh(endpoint.url.absoluteString) }
        catch { runtime.error = error.localizedDescription }
    }
    private func updateDraft(_ value: String) {
        // Inspect the entire paste before limiting its in-memory display; truncation must not remove a credential marker.
        endpointInput = String(value.prefix(4096))
        if OllamaWidgetEndpoint.draftCanPersist(value) { set("ollamaEndpointDraft", value) }
    }
    private func synchronize(_ incoming: [String: String]) {
        let safe = OllamaWidgetEndpoint.sanitizedConfiguration(incoming)
        let replaceInput = endpointInput == storedDraft
        if safe["ollamaEndpoint"] != config["ollamaEndpoint"] { runtime.disconnect() }
        config = safe
        if replaceInput { endpointInput = storedDraft }
        if safe != incoming { publishConfiguration() }
    }
    private func publishConfiguration() { var updated = item; updated.configuration = config; onUpdate(updated) }
    private func set(_ key: String, _ value: String) {
        guard config[key] != value else { return }
        config[key] = value; publishConfiguration()
    }
}

private struct OllamaWidgetModelRow: View {
    let model: OllamaWidgetModel
    let running: Bool
    let stamp: Date
    private var detail: String { [model.family, model.parameters, model.quantization].compactMap { $0 }.joined(separator: " · ") }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.name).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 12) {
                if let bytes = model.bytes { Text((running ? "内存 " : "大小 ") + format(bytes)) }
                if running, let bytes = model.vramBytes { Text("VRAM " + format(bytes)) }
            }.font(.caption).foregroundStyle(.secondary)
            if running {
                if let expires = model.expiresAt {
                    Text((expires <= stamp ? "采样时已到释放期限：" : "释放期限：") + expires.formatted(date: .abbreviated, time: .standard)).font(.caption)
                } else { Text("服务未报告释放期限").font(.caption).foregroundStyle(.secondary) }
                if let context = model.contextLength { Text("上下文长度 \(context.formatted())").font(.caption).foregroundStyle(.secondary) }
            } else if let modified = model.modifiedAt { Text("更新于 " + modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).dockCard(cornerRadius: 12)
    }
    private func format(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary) }
}
