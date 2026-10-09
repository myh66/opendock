import SwiftUI

struct WidgetLibraryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category = "全部"
    @FocusState private var searchFocused: Bool
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAddWidgets: Bool { store.selected?.kind == .custom }
    private var categories: [String] { ["全部"] + ["效率", "时间", "系统", "生活", "商业", "AI"].filter { name in WidgetKind.allCases.contains { $0.category == name } } }
    private var widgets: [WidgetKind] {
        WidgetKind.allCases.filter { widget in
            (category == "全部" || widget.category == category) && matchesQuery(widget)
        }
    }
    private var allMatchingCount: Int { WidgetKind.allCases.filter(matchesQuery).count }
    private func matchesQuery(_ widget: WidgetKind) -> Bool {
        query.isEmpty || [widget.title, widget.rawValue, widget.detail, widget.category, widget.symbol].contains { $0.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WidgetPopoverHeader(title: "添加小组件", symbol: "square.grid.2x2", tint: DockTheme.accent,
                                subtitle: "\(WidgetKind.allCases.count) 种选择，点按即可添加到当前 Dock。", onClose: { dismiss() }) { EmptyView() }
            searchField
            categoryFilters
            HStack {
                Text(query.isEmpty ? (category == "全部" ? "全部小组件" : category + "小组件") : "搜索结果").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(widgets.count) 个").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            if widgets.isEmpty { emptyResults }
            else { widgetGrid }
            footer
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
            TextField("搜索名称、用途或服务", text: $search).font(.system(size: 13)).textFieldStyle(.plain)
                .focused($searchFocused).accessibilityLabel("搜索小组件")
                .accessibilityHint("唯一匹配结果时，按回车即可添加")
                .onSubmit { if canAddWidgets, widgets.count == 1, let widget = widgets.first { store.addWidget(widget) } }
            Button { search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(DockIconButtonStyle()).help("清除搜索").accessibilityLabel("清除搜索")
                .disabled(search.isEmpty).opacity(search.isEmpty ? 0 : 1).accessibilityHidden(search.isEmpty)
        }.padding(.horizontal, 14).padding(.vertical, 7).dockCard(cornerRadius: 13)
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(searchFocused ? DockTheme.accent : .clear, lineWidth: 1.5).allowsHitTesting(false))
    }
    private var categoryFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            DockGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { title in
                        Button { category = title } label: {
                            HStack(spacing: 6) {
                                Text(title).font(.system(size: 13, weight: category == title ? .semibold : .medium))
                                Text("\(count(title))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            }.padding(.horizontal, 12).frame(minHeight: 34).dockCard(cornerRadius: 10)
                        }.buttonStyle(DockSelectableCardStyle(selected: category == title, cornerRadius: 10))
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
                ForEach(widgets) { widget in WidgetLibraryOption(widget: widget) { store.addWidget(widget) }.disabled(!canAddWidgets) }
            }.padding(.bottom, 3)
        }
    }
    private var emptyResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text("没有找到匹配的小组件").font(.headline)
            Text(category == "全部" ? "试试更短的名称，或搜索时钟、天气、AI 等用途。" : "当前分类没有匹配结果，可以切换到全部分类。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if category != "全部", allMatchingCount > 0 {
                Button { category = "全部"; searchFocused = true } label: {
                    Text("在全部分类中搜索（\(allMatchingCount) 个）").font(.system(size: 13))
                        .padding(.horizontal, 12).frame(minHeight: 34).dockCard(cornerRadius: 10)
                }.buttonStyle(DockSelectableCardStyle())
            }
            Button { search = ""; category = "全部"; searchFocused = true } label: {
                Text("清除筛选").font(.system(size: 13)).padding(.horizontal, 12).frame(minHeight: 34).dockCard(cornerRadius: 10)
            }.buttonStyle(DockSelectableCardStyle())
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).dockCard(cornerRadius: 18)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !canAddWidgets {
                Label("请先选择自定义 Dock，再添加小组件。", systemImage: "info.circle").foregroundStyle(.primary)
            } else {
                Text("点按添加 · 搜索仅有一个结果时按 ↩ 添加 · ⌘F 搜索").foregroundStyle(.secondary)
            }
            Label("需要权限或账号的小组件，会在你主动连接时请求授权。", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}

private struct WidgetLibraryOption: View {
    let widget: WidgetKind
    let add: () -> Void
    var body: some View {
        Button(action: add) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: widget.symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(DockTheme.accent).frame(width: 34, height: 34)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(widget.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(widget.category).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(DockTheme.accent).accessibilityHidden(true)
                }
                Text(widget.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(14).frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading).dockCard(cornerRadius: 16)
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(DockSelectableCardStyle()).help(widget.title + "：" + widget.detail)
            .accessibilityElement(children: .ignore).accessibilityLabel("添加" + widget.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(widget.category + "，" + widget.detail).accessibilityHint("添加到当前自定义 Dock并关闭选择器")
    }
}
