import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ManagerView: View {
    @EnvironmentObject var store: AppStore
    @State private var page = "docks"
    @State private var showingLink = false
    @State private var linkTitle = ""
    @State private var linkURL = "https://"
    @State private var dragging: UUID?
    @State private var confirmDelete: DockProfile?
    @State private var confirmNative: DockProfile?
    @State private var groupName = "应用分组"

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 224)
            Rectangle().fill(DockTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                if page == "settings" { SettingsView().padding(30) }
                else if page == "about" { about }
                else if let profile = store.selected { editor(profile) }
                else { emptyState }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DockTheme.canvas)
        }
        .foregroundStyle(DockTheme.ink)
        .preferredColorScheme(.light)
        .frame(minWidth: 940, minHeight: 680)
        .tint(DockTheme.accent)
        .sheet(isPresented: $store.widgetLibraryPresented) { WidgetLibraryView() }
        .sheet(isPresented: $showingLink) { linkSheet }
        .alert("无法完成操作", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("删除这个布局？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("取消", role: .cancel) { confirmDelete = nil }
            Button("删除布局", role: .destructive) { if let profile = confirmDelete { store.deleteProfile(profile.id) }; confirmDelete = nil }
        } message: { Text("只删除 OpenDock 中的保存记录。") }
        .alert("应用系统 Dock 布局？", isPresented: Binding(get: { confirmNative != nil }, set: { if !$0 { confirmNative = nil } })) {
            Button("取消", role: .cancel) { confirmNative = nil }
            Button("应用布局") { if let profile = confirmNative { store.activate(profile) }; confirmNative = nil }
        } message: { Text("将替换系统 Dock 中固定的应用和分隔符，并重新启动 Dock。原布局会自动备份，可在设置中恢复。") }
        .onChange(of: store.settingsPresented) { value in if value { page = "settings"; store.settingsPresented = false } }
        .onChange(of: store.requestedPage) { value in if let value { page = value; store.requestedPage = nil } }
        .onChange(of: store.selectedID) { _ in page = "docks" }
        .onAppear {
            if store.settingsPresented { page = "settings"; store.settingsPresented = false }
            if let requested = store.requestedPage { page = requested; store.requestedPage = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenDock").font(.system(size: 17, weight: .semibold))
                    Text("让桌面，跟随你。 ").font(.system(size: 10)).foregroundStyle(DockTheme.secondary)
                }
            }.padding(.top, 48).padding(.bottom, 30).padding(.horizontal, 22)
            Button { page = "docks" } label: {
                HStack { Image(systemName: "square.grid.2x2"); Text("我的 Dock"); Spacer(); Text("\(store.profiles.count)").font(.caption).foregroundStyle(DockTheme.secondary) }
                    .padding(12).background(page == "docks" ? DockTheme.accent.opacity(0.09) : .clear).clipShape(RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.horizontal, 14)
            HStack { Text("保存的布局").font(.system(size: 10, weight: .medium)).foregroundStyle(DockTheme.secondary); Spacer()
                Menu { Button("自定义 Dock") { store.createProfile(kind: .custom); page = "docks" }; Button("保存当前 macOS Dock") { store.captureNative(); page = "docks" }; Button("空白 macOS 布局") { store.createProfile(kind: .native); page = "docks" } } label: { Image(systemName: "plus").font(.system(size: 12)) }.menuStyle(.borderlessButton).frame(width: 20)
            }.padding(.horizontal, 26).padding(.top, 30).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(store.profiles) { profile in
                        Button { store.selectedID = profile.id; page = "docks" } label: {
                            HStack(spacing: 11) {
                                Circle().fill(Color(hex: profile.color)).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 4) { Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(profile.kind.title).font(.system(size: 10)).foregroundStyle(DockTheme.secondary) }
                                Spacer()
                                if store.archive.activeCustomID == profile.id || store.archive.activeNativeID == profile.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DockTheme.accent) }
                            }.padding(.horizontal, 13).padding(.vertical, 12).background(store.selectedID == profile.id && page == "docks" ? Color.white : Color.clear).clipShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).contextMenu {
                            Button("复制布局") { store.duplicate(profile) }
                            Button("删除布局", role: .destructive) { confirmDelete = profile }.disabled(store.profiles.count <= 1)
                        }
                    }
                }.padding(.horizontal, 14)
            }
            Spacer(minLength: 12)
            VStack(spacing: 3) {
                sidebarButton("外观与设置", symbol: "slider.horizontal.3", target: "settings")
                sidebarButton("关于 OpenDock", symbol: "info.circle", target: "about")
            }.padding(.horizontal, 14)
            HStack(spacing: 6) { Circle().fill(Color(hex: "62B393")).frame(width: 5, height: 5); Text("开源 · 本地优先").font(.system(size: 10)); Spacer(); Text("0.1.0").font(.system(size: 10)) }.foregroundStyle(DockTheme.secondary).padding(23)
        }.frame(maxHeight: .infinity).background(Color(hex: "F1F1F7"))
    }

    private func sidebarButton(_ title: String, symbol: String, target: String) -> some View {
        Button { page = target } label: { HStack(spacing: 11) { Image(systemName: symbol).frame(width: 16); Text(title); Spacer() }.font(.system(size: 12)).padding(12).background(page == target ? Color.white : Color.clear).clipShape(RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
    }
    private var header: some View {
        HStack {
            HStack(spacing: 7) { Text("工作空间").foregroundStyle(DockTheme.secondary); Image(systemName: "chevron.right").font(.system(size: 8)); Text(page == "settings" ? "设置" : page == "about" ? "关于" : "我的 Dock") }.font(.system(size: 11))
            Spacer()
            Button { store.importArchive() } label: { Label("导入", systemImage: "square.and.arrow.down") }.buttonStyle(.plain)
            Button { store.exportArchive() } label: { Label("导出", systemImage: "square.and.arrow.up") }.buttonStyle(.plain).padding(.leading, 16)
        }.font(.system(size: 11)).padding(.horizontal, 30).padding(.top, 27).padding(.bottom, 22)
    }

    private func editor(_ profile: DockProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(profile.kind.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(DockTheme.accent)
                        TextField("布局名称", text: Binding(get: { store.profiles.first { $0.id == profile.id }?.name ?? "" }, set: { name in if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.updateProfile(profile.id) { $0.name = name } } }))
                            .textFieldStyle(.plain).font(.system(size: 31, weight: .semibold)).frame(maxWidth: 420)
                        Text(profile.kind == .custom ? "常用的应用和小组件，在需要的时候刚好在场。" : "保存你的系统 Dock，随时切换到另一种工作状态。")
                            .font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
                    }
                    Spacer()
                    Button {
                        if profile.kind == .native { confirmNative = profile } else { store.activate(profile) }
                    } label: {
                        HStack(spacing: 7) { Image(systemName: "checkmark.circle"); Text(store.archive.activeCustomID == profile.id ? "当前布局" : "使用此布局") }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 17).padding(.vertical, 11)
                    }.buttonStyle(.plain).foregroundStyle(.white).background(DockTheme.accent).clipShape(RoundedRectangle(cornerRadius: 10)).disabled(store.applyingNative)
                }

                preview(profile)

                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("布局中的项目").font(.system(size: 15, weight: .semibold)); Text("拖拽调整顺序 · 右键查看更多操作").font(.system(size: 11)).foregroundStyle(DockTheme.secondary) }
                    Spacer()
                    addMenu(profile).buttonStyle(QuietButtonStyle())
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    ForEach(profile.items) { item in itemCard(item, profile: profile) }
                    Button {
                        if profile.kind == .custom { store.widgetLibraryPresented = true } else { store.addItems(AppService.chooseItems(kind: .app)) }
                    } label: {
                        VStack(spacing: 10) { Image(systemName: "plus").font(.system(size: 21, weight: .light)); Text(profile.kind == .custom ? "添加组件" : "添加应用").font(.system(size: 11)) }.frame(maxWidth: .infinity).frame(height: 120).foregroundStyle(DockTheme.secondary).background(RoundedRectangle(cornerRadius: 13).stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color(hex: "D6D5E4")))
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 10) {
                    Image(systemName: "keyboard").foregroundStyle(DockTheme.accent)
                    Text("⌘ ⌥ \(min((store.profiles.firstIndex { $0.id == profile.id } ?? 0) + 1, 9))").font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("通过菜单栏或快捷键切换布局").font(.system(size: 11)).foregroundStyle(DockTheme.secondary)
                    Spacer()
                    Menu { ForEach(["8B7BF4", "5EAF97", "D49566", "699DCF", "D2799F"], id: \.self) { hex in Button(hex) { store.updateProfile(profile.id) { $0.color = hex } } } } label: { Label("布局颜色", systemImage: "paintpalette") }.menuStyle(.borderlessButton).frame(width: 95)
                }.padding(16).background(Color(hex: "F0EEF9")).clipShape(RoundedRectangle(cornerRadius: 11))
                if let notice = store.notice { Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color(hex: "4B9B7E")) }
            }.padding(.horizontal, 30).padding(.top, 8).padding(.bottom, 30)
        }
    }

    private func preview(_ profile: DockProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { HStack(spacing: 5) { Circle().fill(.red.opacity(0.65)); Circle().fill(.orange.opacity(0.65)); Circle().fill(.green.opacity(0.65)) }.frame(width: 39, height: 7); Spacer(); Text("DOCK 预览").font(.system(size: 8, weight: .medium)).tracking(1.7).foregroundStyle(.white.opacity(0.7)); Spacer(); Color.clear.frame(width: 39, height: 7) }.padding(17)
            Spacer(minLength: 22)
            HStack { Spacer(); ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(profile.items) { item in
                        Group {
                            if item.kind == .widget { WidgetTile(item: item, compact: false, onUpdate: { store.updateItem($0, profileID: profile.id) }) }
                            else if item.kind == .spacer { Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 38).padding(.horizontal, 4) }
                            else { AppIconView(item: item, size: 44).help(item.title) }
                        }
                        .onDrag { dragging = item.id; return NSItemProvider(object: item.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: ItemReorderDelegate(itemID: item.id, profileID: profile.id, dragging: $dragging, store: store))
                    }
                    if profile.items.isEmpty { Text("添加应用，开始打造你的 Dock").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).padding(18) }
                }.padding(12)
            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: 640).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.25))); Spacer() }
            Spacer(minLength: 18)
            HStack { Spacer(); Text(profile.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7)); Spacer() }.padding(.bottom, 20)
        }
        .frame(height: 216)
        .background {
            ZStack {
                LinearGradient(colors: [Color(hex: "9389C3"), Color(hex: "676F99"), Color(hex: "A998B7")], startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse().fill(Color(hex: "C6BADA").opacity(0.32)).frame(width: 530, height: 350).rotationEffect(.degrees(-28)).offset(x: 230, y: 160).blur(radius: 30)
                Ellipse().fill(Color(hex: "C4B9E4").opacity(0.28)).frame(width: 480, height: 240).rotationEffect(.degrees(-28)).offset(x: -250, y: -140).blur(radius: 25)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 17))
    }

    private func itemCard(_ item: DockItem, profile: DockProfile) -> some View {
        VStack(spacing: 10) {
            if let widget = item.widget { Image(systemName: widget.symbol).font(.system(size: 25, weight: .light)).foregroundStyle(DockTheme.accent).frame(height: 44) }
            else if item.kind == .spacer { Image(systemName: "rectangle.split.2x1").font(.system(size: 22, weight: .light)).foregroundStyle(DockTheme.secondary).frame(height: 44) }
            else { AppIconView(item: item, size: 44) }
            Text(item.title.isEmpty ? "分隔符" : item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(item.widget?.category ?? (item.kind == .app ? "应用" : item.kind == .appGroup ? "应用分组" : item.kind == .folder ? "文件夹" : item.kind == .link ? "链接" : item.kind == .spacer ? "留白" : "文件")).font(.system(size: 9)).foregroundStyle(DockTheme.secondary)
        }.frame(maxWidth: .infinity).frame(height: 120).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(DockTheme.line))
            .onDrag { dragging = item.id; return NSItemProvider(object: item.id.uuidString as NSString) }
            .onDrop(of: [.text], delegate: ItemReorderDelegate(itemID: item.id, profileID: profile.id, dragging: $dragging, store: store))
            .contextMenu {
                if item.kind != .spacer && item.kind != .widget { Button("打开") { AppService.open(item) } }
                Button("复制") { var copy = item; copy.id = UUID(); store.addItems([copy], to: profile.id) }
                Button("向前移动") { store.updateProfile(profile.id) { p in if let i = p.items.firstIndex(where: { $0.id == item.id }), i > 0 { p.items.swapAt(i, i - 1) } } }
                Button("向后移动") { store.updateProfile(profile.id) { p in if let i = p.items.firstIndex(where: { $0.id == item.id }), i + 1 < p.items.count { p.items.swapAt(i, i + 1) } } }
                Divider()
                Button("移除", role: .destructive) { store.updateProfile(profile.id) { $0.items.removeAll { $0.id == item.id } } }
            }
    }
    private func addMenu(_ profile: DockProfile) -> some View {
        Menu {
            Button("应用…") { store.addItems(AppService.chooseItems(kind: .app)) }
            if profile.kind == .custom {
                Button("组件库…") { store.widgetLibraryPresented = true }
                Button("文件夹…") { store.addItems(AppService.chooseItems(kind: .folder)) }
                Button("文件…") { store.addItems(AppService.chooseItems(kind: .file)) }
                Button("网页链接…") { showingLink = true }
                Button("应用分组…") {
                    let apps = AppService.chooseItems(kind: .app)
                    if !apps.isEmpty { let data = (try? JSONEncoder().encode(apps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"; store.addItems([DockItem(kind: .appGroup, title: "应用分组", configuration: ["apps": data])]) }
                }
            }
            Divider()
            Button("分隔符") { store.addItems([DockItem(kind: .spacer, configuration: ["size": "regular"])]) }
            Button("小分隔符") { store.addItems([DockItem(kind: .spacer, configuration: ["size": "small"])]) }
        } label: { Label("添加项目", systemImage: "plus").font(.system(size: 11, weight: .medium)) }
        .menuStyle(.borderlessButton).fixedSize()
    }
    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加网页链接").font(.title2.bold())
            TextField("名称", text: $linkTitle).textFieldStyle(.roundedBorder)
            TextField("https://example.com", text: $linkURL).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("取消") { showingLink = false }; Button("添加") {
                guard let url = URL(string: linkURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return }
                store.addItems([DockItem(kind: .link, title: linkTitle.isEmpty ? url.host! : linkTitle, target: url.absoluteString)]); showingLink = false; linkTitle = ""; linkURL = "https://"
            }.buttonStyle(.borderedProminent).disabled(URL(string: linkURL)?.host == nil) }
        }.padding(28).frame(width: 420)
    }
    private var emptyState: some View { VStack(spacing: 12) { BrandMark(size: 60); Text("给你的桌面一个新开始。").font(.title2); Button("创建自定义 Dock") { store.createProfile(kind: .custom) }.buttonStyle(.borderedProminent) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
    private var about: some View {
        VStack(spacing: 18) {
            BrandMark(size: 88)
            Text("OpenDock").font(.system(size: 32, weight: .semibold))
            Text("你的桌面，由你安排。").font(.system(size: 14)).foregroundStyle(DockTheme.secondary)
            Text("原生 macOS · 开源 · 无账号 · 无遥测").font(.system(size: 11)).foregroundStyle(DockTheme.accent)
            Text("v0.1.0 Beta · MIT License").font(.system(size: 11)).foregroundStyle(DockTheme.secondary)
            Link("查看源代码 ↗", destination: URL(string: "https://github.com/myh66/opendock")!).padding(.top, 10)
            Text("基于 Dockset 公开功能说明独立实现。\nOpenDock 与 Dockset 及其开发者无关联。")
                .font(.system(size: 11)).foregroundStyle(DockTheme.secondary).multilineTextAlignment(.center).padding(.top, 25)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ItemReorderDelegate: DropDelegate {
    let itemID: UUID
    let profileID: UUID
    @Binding var dragging: UUID?
    let store: AppStore
    func dropEntered(info: DropInfo) { if let dragging { store.moveItem(dragging, before: itemID, in: profileID) } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
