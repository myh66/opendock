import AppKit
import ImageIO
import SwiftUI

struct ItemEditorSheet: View {
    let native: Bool
    let onSave: (DockItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DockItem
    @State private var iconStyle = "native"
    @State private var color = Color(hex: "8B7BF4")
    @State private var letter = ""
    @State private var symbol = "link"
    @State private var groupApps: [DockItem] = []
    @State private var fetchingIcon = false
    @State private var faviconURL = ""
    @State private var faviconTask: Task<Void, Never>?
    @State private var faviconRequestID: UUID?
    @State private var lastTarget = ""
    @State private var presented = true
    @State private var error = ""

    private let symbols = ["link", "globe", "folder.fill", "star.fill", "heart.fill", "bookmark.fill", "briefcase.fill", "house.fill", "bolt.fill", "terminal.fill", "hammer.fill", "paintbrush.fill", "music.note", "gamecontroller.fill", "camera.fill", "doc.fill", "graduationcap.fill", "cart.fill", "tray.fill", "square.stack.3d.up.fill", "sparkles"]

    init(item: DockItem, native: Bool, onSave: @escaping (DockItem) -> Void) {
        self.native = native; self.onSave = onSave
        _draft = State(initialValue: item)
        _lastTarget = State(initialValue: item.target)
        _color = State(initialValue: Color(hex: item.configuration["folderColor"] ?? item.configuration["groupColor"] ?? item.configuration["color"] ?? "8B7BF4"))
        _letter = State(initialValue: item.configuration["folderLetter"] ?? item.configuration["groupName"] ?? item.configuration["letter"] ?? "")
        _symbol = State(initialValue: item.configuration["iconSymbol"] ?? (item.kind == .folder ? "folder.fill" : item.kind == .appGroup ? "square.stack.3d.up.fill" : "link"))
        if let data = item.configuration["apps"]?.data(using: .utf8) { _groupApps = State(initialValue: (try? JSONDecoder().decode([DockItem].self, from: data)) ?? []) }
        let style: String
        if !(item.configuration["iconSymbol"] ?? "").isEmpty { style = "symbol" }
        else if !(item.configuration["faviconPNG"] ?? "").isEmpty { style = "favicon" }
        else if ["folderColor", "folderLetter", "groupColor", "groupName", "letter"].contains(where: { item.configuration[$0] != nil }) || item.kind == .appGroup { style = "letter" }
        else { style = "native" }
        _iconStyle = State(initialValue: style)
        _faviconURL = State(initialValue: item.configuration["faviconURL"] ?? Self.defaultFaviconURL(item.target))
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identityEditor
                    if !native && draft.kind != .widget { iconEditor }
                    if draft.kind == .appGroup { groupEditor }
                    if draft.kind == .widget {
                        editorCard("小组件设置", symbol: "slider.horizontal.3") {
                            Text("保存后，在 Dock 预览中点开对应小组件，可调整它的详细设置。")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(22)
            }.frame(maxHeight: 440)
            Divider()
            DockGlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Text("更改随布局保存在本机。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", action: closeEditor).buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("保存", action: saveDraft).buttonStyle(DockGlassButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction).disabled(!validDraft)
                }
            }.padding(20)
        }
        .frame(width: 570)
        .background(DockAppBackdrop())
        .tint(DockTheme.accent)
        .onChange(of: draft.target, perform: targetChanged)
        .onChange(of: faviconURL) { value in
            cancelFaviconFetch()
            if draft.configuration["faviconURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) != value.trimmingCharacters(in: .whitespacesAndNewlines) {
                draft.configuration.removeValue(forKey: "faviconPNG")
            }
        }
        .onChange(of: iconStyle) { value in if value != "favicon" { cancelFaviconFetch() } }
        .onDisappear { presented = false; cancelFaviconFetch() }
    }

    private var header: some View {
        HStack(spacing: 15) {
            AppIconView(item: configuredDraft, size: 58).padding(12).dockCard(cornerRadius: 20)
            VStack(alignment: .leading, spacing: 7) {
                Text("编辑项目").font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(native ? "名称保存在布局中，系统 Dock 保留应用原始图标。" : "调整名称与图标，让项目更容易辨认。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identityEditor: some View {
        editorCard("基本信息", symbol: "text.alignleft") {
            field("名称", hint: trimmedTitle.isEmpty ? "填写一个便于辨认的名称。" : nil) {
                TextField("项目名称", text: $draft.title).textFieldStyle(.roundedBorder).accessibilityLabel("项目名称")
            }
            if draft.kind == .link {
                field("网页地址") {
                    TextField("https://example.com", text: $draft.target).textFieldStyle(.roundedBorder).accessibilityLabel("网页地址")
                }
                Label(linkHint, systemImage: Self.validWebURL(draft.target) ? "checkmark.circle" : "link")
                    .font(.system(size: 11)).foregroundStyle(Self.validWebURL(draft.target) ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if [.folder, .file, .app].contains(draft.kind) {
                field("位置") {
                    Text(draft.target).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var iconEditor: some View {
        editorCard("图标", symbol: "paintpalette") {
            field("图标样式") {
                Picker("图标样式", selection: $iconStyle) {
                    Text("原始图标").tag("native")
                    Text("系统符号").tag("symbol")
                    if [.folder, .appGroup, .link].contains(draft.kind) { Text("颜色与文字").tag("letter") }
                    if draft.kind == .link { Text("网站图标").tag("favicon") }
                }.labelsHidden().pickerStyle(.segmented)
            }
            if iconStyle == "native" {
                Text("使用项目原始图标；上方预览会立即更新。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if iconStyle == "symbol" {
                field("系统符号名称") {
                    TextField("例如 star.fill", text: $symbol).textFieldStyle(.roundedBorder).accessibilityLabel("SF Symbol 名称")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 7), spacing: 7) {
                    ForEach(symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }, id: \.self) { name in
                        Button { symbol = name } label: {
                            Image(systemName: name).font(.system(size: 16)).frame(maxWidth: .infinity).frame(height: 40)
                                .background(symbol.trimmingCharacters(in: .whitespacesAndNewlines) == name ? DockTheme.accent.opacity(0.14) : Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(symbol.trimmingCharacters(in: .whitespacesAndNewlines) == name ? DockTheme.accent.opacity(0.6) : Color.clear))
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).help(name).accessibilityLabel("选择符号 \(name)")
                            .accessibilityAddTraits(symbol.trimmingCharacters(in: .whitespacesAndNewlines) == name ? .isSelected : [])
                    }
                }
                if !validSymbol { Label("当前系统找不到这个符号，请修改名称或选择上面的图标。", systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange) }
            }
            if iconStyle == "letter" {
                field("图标文字", hint: "最多两个字，也可以留空。") {
                    TextField("例如 工作", text: $letter).textFieldStyle(.roundedBorder).accessibilityLabel("图标文字")
                        .onChange(of: letter) { value in let limited = String(value.prefix(2)); if value != limited { letter = limited } }
                }
            }
            if iconStyle == "letter" || iconStyle == "symbol" {
                ColorPicker("图标颜色", selection: $color, supportsOpacity: false).font(.system(size: 12))
            }
            if iconStyle == "favicon" { faviconEditor }
        }
    }

    private var faviconEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("网站图标地址", hint: "通常是网站的 /favicon.ico，也可填写实际的图片地址。") {
                TextField("https://example.com/favicon.ico", text: $faviconURL).textFieldStyle(.roundedBorder).accessibilityLabel("网站图标 URL")
            }
            DockGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button(fetchingIcon ? "正在读取…" : "读取网站图标", action: startFaviconFetch)
                        .buttonStyle(QuietButtonStyle()).disabled(fetchingIcon || !Self.validWebURL(faviconURL))
                    if fetchingIcon {
                        ProgressView().controlSize(.small)
                        Button("取消读取") { cancelFaviconFetch() }.buttonStyle(QuietButtonStyle())
                    } else if draft.configuration["faviconPNG"] != nil {
                        Button("清除图标") { draft.configuration.removeValue(forKey: "faviconPNG") }.buttonStyle(QuietButtonStyle())
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("已缓存网站图标").accessibilityLabel("已缓存网站图标")
                    }
                }
            }
            if !faviconURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !Self.validWebURL(faviconURL) {
                Label("图标地址需要以 https:// 或 http:// 开头。", systemImage: "link").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text("点击读取时访问该地址，不使用第三方图标服务。图标缓存保存在本机，随布局导出。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var groupEditor: some View {
        editorCard("分组应用", symbol: "square.stack.3d.up") {
            HStack {
                Text("\(groupApps.count) 个应用").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("添加应用…") {
                    for item in AppService.chooseItems(kind: .app) where !groupApps.contains(where: { $0.target == item.target }) { groupApps.append(item) }
                }.buttonStyle(QuietButtonStyle())
            }
            if groupApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 24)).foregroundStyle(DockTheme.accent)
                    Text("还没有应用").font(.system(size: 13, weight: .medium))
                    Text("添加后，从 Dock 点开分组即可选择应用。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            ForEach(Array(groupApps.enumerated()), id: \.element.id) { index, app in
                HStack(spacing: 10) {
                    AppIconView(item: app, size: 28)
                    Text(app.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 5)
                    DockGlassGroup(spacing: 4) {
                        HStack(spacing: 4) {
                            groupButton("将 \(app.title) 向前移动", symbol: "chevron.up", enabled: index > 0) { moveApp(app.id, direction: -1) }
                            groupButton("将 \(app.title) 向后移动", symbol: "chevron.down", enabled: index < groupApps.count - 1) { moveApp(app.id, direction: 1) }
                            groupButton("从分组移除 \(app.title)", symbol: "minus", enabled: true) { groupApps.removeAll { $0.id == app.id } }
                        }
                    }
                }.padding(9).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            }
        }
    }

    private func editorCard<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).dockCard(cornerRadius: 18)
    }
    private func field<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            content().font(.system(size: 12))
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func groupButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 32, height: 32)
                .dockGlass(cornerRadius: 10, interactive: enabled).contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4).help(title).accessibilityLabel(title)
    }
    private func moveApp(_ id: UUID, direction: Int) {
        guard let index = groupApps.firstIndex(where: { $0.id == id }), groupApps.indices.contains(index + direction) else { return }
        groupApps.swapAt(index, index + direction)
    }
    private var trimmedTitle: String { draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validSymbol: Bool { NSImage(systemSymbolName: symbol.trimmingCharacters(in: .whitespacesAndNewlines), accessibilityDescription: nil) != nil }
    private var validDraft: Bool {
        !trimmedTitle.isEmpty && (draft.kind != .link || Self.validWebURL(draft.target)) && (native || draft.kind == .widget || iconStyle != "symbol" || validSymbol)
    }
    private var linkHint: String {
        if draft.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "填写以 https:// 或 http:// 开头的网页地址。" }
        guard Self.validWebURL(draft.target), let host = URLComponents(string: draft.target.trimmingCharacters(in: .whitespacesAndNewlines))?.host else { return "请输入完整的网页地址，例如 https://example.com。" }
        return "点击此项目时打开 \(host)。"
    }
    private var configuredDraft: DockItem {
        var item = draft
        item.title = trimmedTitle
        if item.kind == .link { item.target = item.target.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !native else { return item }
        if item.kind == .appGroup { item.configuration["apps"] = (try? JSONEncoder().encode(groupApps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]" }
        guard item.kind != .widget else { return item }
        for key in ["iconSymbol", "color", "folderColor", "folderLetter", "groupColor", "groupName", "letter"] { item.configuration.removeValue(forKey: key) }
        if iconStyle != "favicon" { item.configuration.removeValue(forKey: "faviconPNG") }
        if iconStyle == "symbol" { item.configuration["iconSymbol"] = symbol.trimmingCharacters(in: .whitespacesAndNewlines); item.configuration["color"] = hexColor }
        if iconStyle == "letter" {
            item.configuration["letter"] = String(letter.prefix(2)); item.configuration["color"] = hexColor
            if item.kind == .folder { item.configuration["folderColor"] = hexColor; item.configuration["folderLetter"] = String(letter.prefix(2)) }
            if item.kind == .appGroup { item.configuration["groupColor"] = hexColor; item.configuration["groupName"] = String(letter.prefix(2)) }
        }
        if iconStyle == "favicon" { item.configuration["faviconURL"] = faviconURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        return item
    }
    private var hexColor: String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "8B7BF4" }
        func component(_ value: CGFloat) -> Int { value.isFinite ? Int((min(1, max(0, value)) * 255).rounded()) : 0 }
        return String(format: "%02X%02X%02X", component(rgb.redComponent), component(rgb.greenComponent), component(rgb.blueComponent))
    }
    private static func validWebURL(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), let url = parts.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return false }
        return true
    }
    private static func defaultFaviconURL(_ target: String) -> String {
        guard validWebURL(target), var parts = URLComponents(string: target.trimmingCharacters(in: .whitespacesAndNewlines)) else { return "" }
        parts.user = nil; parts.password = nil; parts.path = "/favicon.ico"; parts.query = nil; parts.fragment = nil
        return parts.string ?? ""
    }
    private func targetChanged(_ value: String) {
        cancelFaviconFetch()
        let previousDefault = Self.defaultFaviconURL(lastTarget)
        if faviconURL.trimmingCharacters(in: .whitespacesAndNewlines) == previousDefault || faviconURL.isEmpty { faviconURL = Self.defaultFaviconURL(value) }
        lastTarget = value
    }
    private func closeEditor() { presented = false; cancelFaviconFetch(); dismiss() }
    private func saveDraft() {
        guard validDraft else { return }
        let item = configuredDraft
        presented = false; cancelFaviconFetch(); onSave(item); dismiss()
    }
    private func cancelFaviconFetch() {
        faviconRequestID = nil
        faviconTask?.cancel(); faviconTask = nil
        fetchingIcon = false; error = ""
    }
    private func startFaviconFetch() {
        let address = faviconURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard presented, Self.validWebURL(address), !fetchingIcon else { return }
        cancelFaviconFetch()
        let id = UUID(), target = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
        faviconRequestID = id; fetchingIcon = true
        faviconTask = Task { @MainActor in await fetchFavicon(id: id, address: address, target: target) }
    }
    @MainActor private func fetchFavicon(id: UUID, address: String, target: String) async {
        defer { if faviconRequestID == id { faviconRequestID = nil; fetchingIcon = false; faviconTask = nil } }
        func isCurrent() -> Bool {
            !Task.isCancelled && presented && faviconRequestID == id && iconStyle == "favicon" &&
                faviconURL.trimmingCharacters(in: .whitespacesAndNewlines) == address && draft.target.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }
        guard let url = URL(string: address), isCurrent() else { return }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 15
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard isCurrent() else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count <= 1_000_000,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) else {
                error = "网址未返回可用图片，请填写该站实际的图标地址。"; return
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 500_000 else { error = "图标无法转换或过大。"; return }
            try Task.checkCancellation()
            guard isCurrent() else { return }
            draft.configuration["faviconPNG"] = png.base64EncodedString()
            draft.configuration["faviconURL"] = address
        } catch {
            let networkError = error as NSError
            guard isCurrent(), !(error is CancellationError), !(networkError.domain == NSURLErrorDomain && networkError.code == NSURLErrorCancelled) else { return }
            self.error = error.localizedDescription
        }
    }
}
