import SwiftUI

struct WidgetLibraryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category = "全部"
    private var widgets: [WidgetKind] { WidgetKind.allCases.filter { (category == "全部" || $0.category == category) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.rawValue.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 7) { Text("多一点，刚刚好。").font(.system(size: 25, weight: .semibold)); Text("把实用的小组件，放进你的 Dock。").font(.system(size: 12)).foregroundStyle(DockTheme.secondary) }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DockTheme.secondary).font(.title2) }.buttonStyle(.plain) }
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(DockTheme.secondary); TextField("搜索组件", text: $search).textFieldStyle(.plain) }.padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 8) { ForEach(["全部", "效率", "时间", "系统", "生活"], id: \.self) { title in Button { category = title } label: { Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 15).padding(.vertical, 8).background(category == title ? DockTheme.accent : .white).foregroundStyle(category == title ? .white : DockTheme.secondary).clipShape(Capsule()) }.buttonStyle(.plain) } }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 13) {
                    ForEach(widgets) { widget in
                        Button { store.addWidget(widget) } label: {
                            VStack(alignment: .leading, spacing: 13) {
                                HStack { Image(systemName: widget.symbol).font(.system(size: 25, weight: .light)).foregroundStyle(DockTheme.accent); Spacer(); Image(systemName: "plus.circle").foregroundStyle(DockTheme.secondary.opacity(0.6)) }
                                Text(widget.title).font(.system(size: 13, weight: .semibold))
                                Text(widget.detail).font(.system(size: 10)).foregroundStyle(DockTheme.secondary).lineLimit(2).frame(height: 30, alignment: .top)
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white).clipShape(RoundedRectangle(cornerRadius: 13))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("需要权限或连接的组件，会在你主动连接时请求授权。").font(.system(size: 10)).foregroundStyle(DockTheme.secondary)
        }.padding(28).frame(width: 720, height: 610).background(DockTheme.canvas).foregroundStyle(DockTheme.ink).preferredColorScheme(.light)
    }
}
