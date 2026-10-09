import SwiftUI

struct WidgetLibraryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category = "全部"
    @FocusState private var searchFocused: Bool
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var categories: [String] { ["全部"] + ["效率", "时间", "系统", "生活", "商业", "AI"].filter { name in WidgetKind.allCases.contains { $0.category == name } } }
    private var widgets: [WidgetKind] {
        WidgetKind.allCases.filter { widget in
            (category == "全部" || widget.category == category) && (query.isEmpty || [widget.title, widget.rawValue, widget.detail, widget.category, widget.symbol].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WidgetPopoverHeader(title: "添加小组件", symbol: "square.grid.2x2", tint: DockTheme.accent,
                                subtitle: "\(WidgetKind.allCases.count) 种选择，把常用信息留在 Dock。", onClose: { dismiss() }) { EmptyView() }
            searchField
            categoryFilters
            HStack {
                Text(query.isEmpty ? (category == "全部" ? "全部小组件" : category + "小组件") : "搜索结果").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(widgets.count) 个").font(.caption).foregroundStyle(.secondary)
            }
            if widgets.isEmpty { emptyResults }
            else { widgetGrid }
            Label("需要权限或账号的小组件，会在你主动连接时请求授权。", systemImage: "lock.shield")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(24).frame(width: 720, height: 640)
            .background(DockAppBackdrop()).foregroundStyle(.primary)
            .onAppear { searchFocused = true }
            .onExitCommand { dismiss() }
            .background {
                HStack {
                    Button("关闭小组件选择器") { dismiss() }.keyboardShortcut("w", modifiers: .command)
                    Button("搜索小组件") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
    }
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("搜索名称、用途或服务", text: $search).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("搜索小组件")
            Button { search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 32, height: 32) }
                .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索").disabled(search.isEmpty).opacity(search.isEmpty ? 0 : 1).accessibilityHidden(search.isEmpty)
        }.padding(.horizontal, 14).padding(.vertical, 7).dockCard(cornerRadius: 13)
    }
    private var categoryFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            DockGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { title in
                        Button { category = title } label: { HStack(spacing: 5) { Text(title); Text("\(count(title))").font(.caption2).opacity(0.8) } }
                            .buttonStyle(DockGlassButtonStyle(prominent: category == title))
                            .accessibilityLabel(title + "，\(count(title)) 个小组件").accessibilityValue(category == title ? "已选中" : "")
                    }
                }.padding(.vertical, 2)
            }
        }
    }
    private func count(_ title: String) -> Int { title == "全部" ? WidgetKind.allCases.count : WidgetKind.allCases.filter { $0.category == title }.count }
    private var widgetGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                ForEach(widgets) { widget in WidgetLibraryOption(widget: widget) { store.addWidget(widget) } }
            }.padding(.bottom, 3)
        }
    }
    private var emptyResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text("没有找到匹配的小组件").font(.headline)
            Text(category == "全部" ? "试试更短的名称，或搜索时钟、天气、AI 等用途。" : "当前分类没有匹配结果，可以切换到全部分类。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("清除筛选") { search = ""; category = "全部"; searchFocused = true }.buttonStyle(DockGlassButtonStyle())
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).dockCard(cornerRadius: 18)
    }
}

private struct WidgetLibraryOption: View {
    let widget: WidgetKind
    let add: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: add) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: widget.symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(DockTheme.accent).frame(width: 34, height: 34)
                        .dockGlass(cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 3) { Text(widget.title).font(.system(size: 13, weight: .semibold)); Text(widget.category).font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(DockTheme.accent)
                }
                Text(widget.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(height: 32, alignment: .topLeading)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).dockCard(cornerRadius: 16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(hovered ? DockTheme.accent.opacity(0.55) : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityElement(children: .ignore).accessibilityLabel("添加" + widget.title).accessibilityValue(widget.detail).accessibilityHint("添加到当前自定义 Dock")
    }
}
