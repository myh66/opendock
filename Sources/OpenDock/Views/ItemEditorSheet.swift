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
    @State private var error = ""

    init(item: DockItem, native: Bool, onSave: @escaping (DockItem) -> Void) {
        self.native = native; self.onSave = onSave
        _draft = State(initialValue: item)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                AppIconView(item: configuredDraft, size: 52)
                VStack(alignment: .leading, spacing: 4) { Text("编辑项目").font(.title2.bold()); Text(native ? "名称修改保存到布局；macOS Dock 使用应用原始图标。" : "设置会随布局保存与导出。").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("名称", text: $draft.title).textFieldStyle(.roundedBorder)
                    if draft.kind == .link {
                        TextField("网页 URL", text: $draft.target).textFieldStyle(.roundedBorder)
                            .onChange(of: draft.target) { value in if draft.configuration["faviconURL"] == nil { faviconURL = Self.defaultFaviconURL(value) } }
                    }
                    if !native && draft.kind != .widget { iconEditor }
                    if draft.kind == .appGroup { groupEditor }
                    if draft.kind == .widget {
                        Text("小组件详细设置可通过 Dock 预览中的对应小组件打开。").font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.kind == .folder || draft.kind == .file || draft.kind == .app { Text(draft.target).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(configuredDraft); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!validDraft)
            }
        }.padding(26).frame(width: 485)
    }

    private var iconEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("图标", selection: $iconStyle) {
                Text("原始图标").tag("native")
                Text("系统符号").tag("symbol")
                if [.folder, .appGroup, .link].contains(draft.kind) { Text("颜色与文字").tag("letter") }
                if draft.kind == .link { Text("网站图标").tag("favicon") }
            }
            if iconStyle == "symbol" {
                TextField("SF Symbol 名称", text: $symbol).textFieldStyle(.roundedBorder)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
                    ForEach(["link", "globe", "folder.fill", "star.fill", "heart.fill", "bookmark.fill", "briefcase.fill", "house.fill", "bolt.fill", "terminal.fill", "hammer.fill", "paintbrush.fill", "music.note", "gamecontroller.fill", "camera.fill", "doc.fill", "graduationcap.fill", "cart.fill", "tray.fill", "square.stack.3d.up.fill", "sparkles"], id: \.self) { name in
                        Button { symbol = name } label: { Image(systemName: name).frame(width: 29, height: 29).background(symbol == name ? DockTheme.accent.opacity(0.15) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5)) }.buttonStyle(.plain).help(name)
                    }
                }
                if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil { Text("系统找不到这个符号。").font(.caption).foregroundStyle(.red) }
            }
            if iconStyle == "letter" { TextField("图标文字（最多两个字）", text: $letter).textFieldStyle(.roundedBorder).onChange(of: letter) { letter = String($0.prefix(2)) } }
            if iconStyle == "letter" || iconStyle == "symbol" { ColorPicker("图标颜色", selection: $color, supportsOpacity: false) }
            if iconStyle == "favicon" {
                TextField("网站图标 URL", text: $faviconURL).textFieldStyle(.roundedBorder)
                HStack {
                    Button("读取网站图标") { Task { await fetchFavicon() } }.disabled(fetchingIcon || !Self.validWebURL(faviconURL))
                    if fetchingIcon { ProgressView().controlSize(.small) }
                    if draft.configuration["faviconPNG"] != nil { Button("清除图标") { draft.configuration.removeValue(forKey: "faviconPNG") } }
                }
                Text("点击读取时访问指定网站，不使用第三方图标服务。图片保存在本机，随布局导出。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("分组中的应用（\(groupApps.count)）").font(.headline); Spacer(); Button("添加应用…") { let additions = AppService.chooseItems(kind: .app); for item in additions where !groupApps.contains(where: { $0.target == item.target }) { groupApps.append(item) } } }
            if groupApps.isEmpty { Text("选择应用后，可在 Dock 中打开整个分组。").font(.caption).foregroundStyle(.secondary) }
            ForEach(groupApps) { app in
                HStack {
                    AppIconView(item: app, size: 25)
                    Text(app.title).font(.callout).lineLimit(1)
                    Spacer()
                    Button { moveApp(app.id, direction: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).help("向前移动")
                    Button { moveApp(app.id, direction: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).help("向后移动")
                    Button { groupApps.removeAll { $0.id == app.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("从分组移除")
                }
            }
        }
    }

    private func moveApp(_ id: UUID, direction: Int) { guard let index = groupApps.firstIndex(where: { $0.id == id }), groupApps.indices.contains(index + direction) else { return }; groupApps.swapAt(index, index + direction) }
    private var validDraft: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (draft.kind != .link || Self.validWebURL(draft.target)) && (iconStyle != "symbol" || NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    }
    private var configuredDraft: DockItem {
        var item = draft
        guard !native else { return item }
        if item.kind == .appGroup { item.configuration["apps"] = (try? JSONEncoder().encode(groupApps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]" }
        guard item.kind != .widget else { return item }
        for key in ["iconSymbol", "color", "folderColor", "folderLetter", "groupColor", "groupName", "letter"] { item.configuration.removeValue(forKey: key) }
        if iconStyle != "favicon" { item.configuration.removeValue(forKey: "faviconPNG") }
        if iconStyle == "symbol" { item.configuration["iconSymbol"] = symbol; item.configuration["color"] = hexColor }
        if iconStyle == "letter" {
            item.configuration["letter"] = String(letter.prefix(2)); item.configuration["color"] = hexColor
            if item.kind == .folder { item.configuration["folderColor"] = hexColor; item.configuration["folderLetter"] = String(letter.prefix(2)) }
            if item.kind == .appGroup { item.configuration["groupColor"] = hexColor; item.configuration["groupName"] = String(letter.prefix(2)) }
        }
        if iconStyle == "favicon" { item.configuration["faviconURL"] = faviconURL }
        return item
    }
    private var hexColor: String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "8B7BF4" }
        return String(format: "%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
    }
    private static func validWebURL(_ text: String) -> Bool { guard let parts = URLComponents(string: text), let url = parts.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, parts.user == nil, parts.password == nil else { return false }; return true }
    private static func defaultFaviconURL(_ target: String) -> String { guard var parts = URLComponents(string: target), parts.host != nil else { return "" }; parts.user = nil; parts.password = nil; parts.path = "/favicon.ico"; parts.query = nil; parts.fragment = nil; return parts.string ?? "" }

    private func fetchFavicon() async {
        guard let url = URL(string: faviconURL), Self.validWebURL(faviconURL), !fetchingIcon else { return }
        fetchingIcon = true; error = ""; defer { fetchingIcon = false }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 15
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count <= 1_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:128] as CFDictionary) else { error = "网址未返回可用图片。可以填写该站实际的 favicon URL。"; return }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 500_000 else { error = "图标无法转换或过大。"; return }
            draft.configuration["faviconPNG"] = png.base64EncodedString(); draft.configuration["faviconURL"] = faviconURL
        } catch { self.error = error.localizedDescription }
    }
}
