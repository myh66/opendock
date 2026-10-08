import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CustomDockView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var windows = WindowMonitor.shared
    @ObservedObject private var popovers = WidgetPopoverCoordinator.shared
    let openManager: () -> Void
    @State private var running: [DockItem] = []
    @State private var dragging: UUID?
    @State private var runningDrag: DockItem?
    @State private var contentLength: CGFloat = 0
    @State private var itemFrames:[UUID:CGRect] = [:]
    @State private var hoverTimer: Timer?
    @State private var resizeStart: Double?
    private var vertical: Bool { store.settings.position != .bottom }
    private var runningExtras: [DockItem] {
        guard store.settings.showRunningApps else { return [] }
        let pinned = Set(store.activeCustom?.items.filter { $0.kind == .app }.map { URL(fileURLWithPath:$0.target).standardizedFileURL.path } ?? [])
        return running.filter { !pinned.contains(URL(fileURLWithPath:$0.target).standardizedFileURL.path) }
    }
    var body: some View {
        VStack(spacing: 5) {
            if let profile = store.activeCustom {
                GeometryReader { geometry in
                    let overflow = contentLength > (vertical ? geometry.size.height : geometry.size.width) + 4
                    ScrollViewReader { proxy in
                        ZStack {
                            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                                Group {
                                    if vertical { VStack(spacing: 8) { items(profile) }.frame(maxWidth: .infinity).padding(12) }
                                    else { HStack(spacing: 8) { items(profile) }.padding(12) }
                                }.background(GeometryReader { size in Color.clear.preference(key: DockLengthKey.self, value: vertical ? size.size.height : size.size.width) })
                            }.coordinateSpace(name:"DockScroll").onPreferenceChange(DockLengthKey.self) { contentLength = $0 }
                            .onPreferenceChange(DockItemFramesKey.self) { itemFrames = $0 }
                            if overflow {
                                if vertical { VStack { chevron(-1, proxy:proxy,profile:profile,viewport:vertical ? geometry.size.height:geometry.size.width); Spacer(); chevron(1,proxy:proxy,profile:profile,viewport:vertical ? geometry.size.height:geometry.size.width) } }
                                else { HStack { chevron(-1,proxy:proxy,profile:profile,viewport:vertical ? geometry.size.height:geometry.size.width); Spacer(); chevron(1,proxy:proxy,profile:profile,viewport:vertical ? geometry.size.height:geometry.size.width) } }
                            }
                        }
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: profile.color)).frame(width: 4,height: 4)
                    Text(profile.name).font(.system(size: 9,weight: .medium)).lineLimit(1)
                    Button { store.settingsPresented = true; openManager() } label: { Image(systemName:"slider.horizontal.3").font(.system(size:10)) }.buttonStyle(.plain).help("设置")
                    Capsule().fill(.secondary.opacity(0.35)).frame(width: 18,height: 3).padding(5).help("拖动调整图标大小")
                        .gesture(DragGesture().onChanged { value in
                            if resizeStart == nil { resizeStart = store.settings.iconSize }
                            let delta = vertical ? -value.translation.width : -value.translation.height
                            store.settings.iconSize = min(80,max(24,(resizeStart ?? 44) + delta / 3))
                        }.onEnded { _ in resizeStart = nil })
                }.foregroundStyle(.secondary).padding(.bottom,8)
            } else { Button("创建 Dock",action:openManager).padding(20) }
        }
        .background { DockSurface(settings:store.settings) }
        .clipShape(RoundedRectangle(cornerRadius:21))
        .overlay(RoundedRectangle(cornerRadius:21).stroke(.white.opacity(0.25),lineWidth:1))
        .preferredColorScheme(store.settings.material == .dark ? .dark : nil).tint(DockTheme.accent)
        .contextMenu {
            Button("管理 Dock…",action:openManager)
            Menu("切换布局") { ForEach(store.profiles.filter { $0.kind == .custom }) { profile in Button(profile.name) { store.activate(profile) } } }
            Button("添加应用…") { if let id = store.activeCustom?.id { store.addItems(AppService.chooseItems(kind:.app),to:id) } }
            Button("添加组件…") { store.selectedID = store.archive.activeCustomID; store.widgetLibraryPresented = true; openManager() }
            Divider(); Button("隐藏 Dock") { store.settings.showCustomDock = false }
        }
        .onDrop(of:[.fileURL,.url],isTargeted:nil,perform:receiveExternal)
        .onAppear(perform:refreshRunning)
        .onDisappear { hoverTimer?.invalidate() }
        .onChange(of:store.archive.activeCustomID) { _ in itemFrames = [:]; hoverTimer?.invalidate() }
        .onChange(of:popovers.activeID) { value in if value != nil { hoverTimer?.invalidate() } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didLaunchApplicationNotification)) { _ in refreshRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunning() }
    }
    @ViewBuilder private func items(_ profile: DockProfile) -> some View {
        ForEach(profile.items) { item in
            Group {
                if item.kind == .widget { WidgetTile(item:item,compact:vertical,onUpdate:{ store.updateItem($0,profileID:profile.id) },onDuplicate:{ store.duplicateItem(item,in:profile.id) }) }
                else if item.kind == .spacer { divider }
                else { DockLauncher(item:item,profileID:profile.id).environmentObject(store) }
            }.id(item.id).background(itemGeometry(item.id))
            .onDrag { dragging = item.id; runningDrag = nil; return NSItemProvider(object:item.id.uuidString as NSString) }
            .onDrop(of:[.text],delegate:DockDropDelegate(targetID:item.id,profileID:profile.id,unpin:false,dragged:$dragging,running:$runningDrag,store:store))
        }
        Color.clear.frame(width:vertical ? 34 : 6,height:vertical ? 6 : 34)
            .onDrop(of:[.text],delegate:DockDropDelegate(targetID:nil,profileID:profile.id,unpin:false,dragged:$dragging,running:$runningDrag,store:store))
        if !runningExtras.isEmpty || store.settings.showMinimizedWindows {
            divider
            ForEach(runningExtras) { item in
                DockLauncher(item:item,profileID:profile.id,pinned:false).environmentObject(store).id(item.id).background(itemGeometry(item.id))
                    .onDrag { dragging = item.id; runningDrag = item; return NSItemProvider(object:item.id.uuidString as NSString) }
                    .onDrop(of:[.text],delegate:DockDropDelegate(targetID:nil,profileID:profile.id,unpin:true,dragged:$dragging,running:$runningDrag,store:store))
            }
            if store.settings.showMinimizedWindows { ForEach(windows.minimized) { window in MinimizedWindowTile(window:window,size:store.settings.iconSize).id(window.id) } }
            Color.clear.frame(width:vertical ? 34 : 6,height:vertical ? 6 : 34)
                .onDrop(of:[.text],delegate:DockDropDelegate(targetID:nil,profileID:profile.id,unpin:true,dragged:$dragging,running:$runningDrag,store:store))
        }
        if store.settings.showTrash { TrashTile(size:store.settings.iconSize) }
    }
    @ViewBuilder private var divider: some View {
        if vertical { Rectangle().fill(.secondary.opacity(0.2)).frame(width:34,height:1).padding(.vertical,4) }
        else { Rectangle().fill(.secondary.opacity(0.2)).frame(width:1,height:34).padding(.horizontal,4) }
    }
    private func chevron(_ direction:Int,proxy:ScrollViewProxy,profile:DockProfile,viewport:CGFloat) -> some View {
        let ids = profile.items.map(\.id) + runningExtras.map(\.id)
        func advance() {
            guard popovers.activeID == nil, !ids.isEmpty else { return }
            let visible = ids.enumerated().compactMap { index,id -> (Int,CGFloat)? in guard let frame = itemFrames[id] else { return nil }; let mid = vertical ? frame.midY:frame.midX; return (index,abs(mid - viewport / 2)) }.min { $0.1 < $1.1 }?.0 ?? 0
            let next = max(0,min(ids.count - 1,visible + direction))
            withAnimation(.easeOut(duration:0.16)) { proxy.scrollTo(ids[next],anchor:.center) }
        }
        return Button(action:advance) { Image(systemName: vertical ? (direction < 0 ? "chevron.up" : "chevron.down") : (direction < 0 ? "chevron.left" : "chevron.right")).font(.system(size:10,weight:.bold)).padding(7).background(.regularMaterial,in:Capsule()) }
            .buttonStyle(.plain).padding(3).onHover { inside in hoverTimer?.invalidate(); if inside && popovers.activeID == nil { hoverTimer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { _ in Task { @MainActor in advance() } } } }
    }
    private func itemGeometry(_ id:UUID)->some View { GeometryReader { proxy in Color.clear.preference(key:DockItemFramesKey.self,value:[id:proxy.frame(in:.named("DockScroll"))]) } }
    private func refreshRunning() { running = AppService.runningApps() }
    private func receiveExternal(_ providers:[NSItemProvider]) -> Bool {
        guard let profileID = store.activeCustom?.id else { return false }
        for provider in providers {
            let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : UTType.url.identifier
            provider.loadDataRepresentation(forTypeIdentifier:type) { data,_ in
                guard let data, let raw = String(data:data,encoding:.utf8), let url = URL(string:raw.trimmingCharacters(in:.whitespacesAndNewlines)) else { return }
                Task { @MainActor in
                    let item:DockItem
                    if url.isFileURL {
                        let directory = (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true
                        item = DockItem(kind:url.pathExtension.lowercased() == "app" ? .app : directory ? .folder : .file,title:url.deletingPathExtension().lastPathComponent,target:url.path)
                    } else { guard ["http","https"].contains(url.scheme ?? "") else { return }; item = DockItem(kind:.link,title:url.host ?? url.absoluteString,target:url.absoluteString) }
                    store.addItems([item],to:profileID)
                }
            }
        }
        return !providers.isEmpty
    }
}
private struct DockLengthKey: PreferenceKey { static var defaultValue:CGFloat = 0; static func reduce(value:inout CGFloat,nextValue:()->CGFloat) { value = max(value,nextValue()) } }
private struct DockDropDelegate:DropDelegate {
    let targetID:UUID?; let profileID:UUID; let unpin:Bool
    @Binding var dragged:UUID?; @Binding var running:DockItem?
    let store:AppStore
    func dropEntered(info:DropInfo) { guard !unpin, running == nil, let id = dragged, let targetID else { return }; store.moveItem(id,before:targetID,in:profileID) }
    func dropUpdated(info:DropInfo)->DropProposal? { DropProposal(operation:.move) }
    func performDrop(info:DropInfo)->Bool {
        defer { dragged = nil; running = nil }
        guard let id = dragged else { return false }
        if unpin {
            guard store.profiles.first(where:{$0.id == profileID})?.items.first(where:{$0.id == id})?.kind == .app else { return false }
            store.removeItems([id],from:profileID)
        } else if let running {
            let item = AppStore.independentCopy(running); store.addItems([item],to:profileID); store.moveItems([item.id],to:targetID,in:profileID)
        } else if targetID == nil { store.moveItems([id],to:nil,in:profileID) }
        return true
    }
}

struct DockLauncher: View {
    @EnvironmentObject var store:AppStore
    @ObservedObject private var windows = WindowMonitor.shared
    @ObservedObject private var coordinator = WidgetPopoverCoordinator.shared
    let item:DockItem; let profileID:UUID; var pinned = true
    @State private var hovered = false
    @State private var browse = false
    @State private var contents:[DockItem] = []
    @State private var hold:Task<Void,Never>?
    @State private var thumbnail:NSImage?
    var body:some View {
        Button {
            if item.kind == .appGroup { loadContents(); browse.toggle() }
            else if item.kind == .app { if !AppService.click(item,minimizeIfActive:store.settings.clickToMinimize) { store.errorMessage = "无法操作应用窗口，请确认应用路径与辅助功能权限。" } }
            else { AppService.open(item) }
        } label: {
            VStack(spacing:3) {
                ZStack(alignment:.topTrailing) {
                    Group { if let thumbnail { Image(nsImage:thumbnail).resizable().scaledToFit().frame(width:store.settings.iconSize,height:store.settings.iconSize).clipShape(RoundedRectangle(cornerRadius:6)) } else { AppIconView(item:item,size:store.settings.iconSize) } }
                        .scaleEffect(hovered && coordinator.activeID == nil && store.settings.magnification && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.14 : 1)
                    if store.settings.showBadges, let badge = windows.badges[URL(fileURLWithPath:item.target).standardizedFileURL.path] { Text(badge).font(.system(size:9,weight:.bold)).foregroundStyle(.white).padding(3).background(.red,in:Capsule()).offset(x:4,y:-3) }
                }
                if item.configuration["showName"] == "true" { Text(item.title).font(.system(size:9)).lineLimit(1).frame(maxWidth:80) }
                Circle().fill(AppService.runningApplication(for:item) != nil ? Color.primary.opacity(0.5) : .clear).frame(width:4,height:4)
            }.padding(3)
        }.buttonStyle(.plain).help(item.title)
        .onHover { inside in
            withAnimation(.easeOut(duration:0.12)) { hovered = inside }
            hold?.cancel()
            if inside && item.kind == .folder && coordinator.activeID == nil { hold = Task { try? await Task.sleep(nanoseconds:700_000_000); guard !Task.isCancelled, coordinator.activeID == nil else { return }; loadContents(); browse = true } }
        }
        .task(id:item.target) { if item.kind == .file { thumbnail = await FilePreviewService.shared.thumbnail(for:URL(fileURLWithPath:item.target),size:CGSize(width:80,height:80)) } }
        .popover(isPresented:$browse) {
            ScrollView {
                VStack(alignment:.leading,spacing:9) {
                    Text(item.title).font(.headline)
                    if contents.isEmpty { Text("这里暂时没有可显示的项目。").foregroundStyle(.secondary) }
                    ForEach(contents) { child in Button { AppService.open(child); browse = false } label: { HStack { AppIconView(item:child,size:24); Text(child.title).lineLimit(1); Spacer() } }.buttonStyle(.plain).contextMenu { Button("快速查看") { FilePreviewService.shared.showQuickLook([URL(fileURLWithPath:child.target)]) }; Button("在 Finder 中显示") { AppService.reveal(child) } } }
                }.padding(18)
            }.frame(width:300,height:min(CGFloat(contents.count * 38 + 70),400)).onExitCommand { browse = false }
        }
        .onChange(of:browse) { open in if open { coordinator.activeID = item.id } else if coordinator.activeID == item.id { coordinator.activeID = nil } }
        .onChange(of:coordinator.activeID) { active in if active != item.id { browse = false } }
        .onDisappear { hold?.cancel(); if coordinator.activeID == item.id { coordinator.activeID = nil } }
        .contextMenu {
            Button("打开") { AppService.open(item) }
            if item.kind == .folder || item.kind == .appGroup { Button("浏览内容") { loadContents(); browse = true } }
            if item.kind == .file { Button("快速查看") { FilePreviewService.shared.showQuickLook([URL(fileURLWithPath:item.target)]) } }
            if item.kind == .app {
                let windows = AppService.applicationWindows(for:item)
                if !windows.isEmpty { Menu("窗口") { ForEach(windows) { window in Button((window.isMinimized ? "↗ " : "") + window.title) { AppService.activateWindow(window) } } } }
                Button("退出应用") { AppService.quit(item) }.disabled(AppService.runningApplication(for:item) == nil)
            }
            if item.kind != .appGroup && item.kind != .link { Button("在 Finder 中显示") { AppService.reveal(item) } }
            Divider()
            if pinned { Button("从 Dock 移除") { store.removeItems([item.id],from:profileID) } }
            else { Button("保留在 Dock 中") { store.addItems([AppStore.independentCopy(item)],to:profileID) } }
        }
    }
    private func loadContents() {
        if item.kind == .appGroup {
            if let data = item.configuration["apps"]?.data(using:.utf8), let apps = try? JSONDecoder().decode([DockItem].self,from:data) { contents = apps }
            else if let data = item.target.data(using:.utf8), let paths = try? JSONDecoder().decode([String].self,from:data) { contents = paths.map { DockItem(kind:.app,title:URL(fileURLWithPath:$0).deletingPathExtension().lastPathComponent,target:$0) } }
        } else {
            let urls = (try? FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:item.target),includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])) ?? []
            contents = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map { url in DockItem(kind:(try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true ? .folder : .file,title:url.lastPathComponent,target:url.path) }
        }
    }
}
private struct MinimizedWindowTile:View {
    let window:MiniWindow; let size:Double
    @State private var preview = false
    var body:some View {
        Button { window.restore() } label: {
            ZStack(alignment:.bottomTrailing) {
                if let image = window.image { Image(nsImage:image).resizable().scaledToFit().frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:6)) }
                else { Image(systemName:"macwindow").font(.system(size:size * 0.5)).frame(width:size,height:size) }
                AppIconView(item:window.appItem,size:18)
            }.padding(3)
        }.buttonStyle(.plain).help(window.title).onHover { preview = $0 }.popover(isPresented:$preview) { VStack { if let image = window.image { Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:320,maxHeight:220) }; Text(window.title).font(.caption).lineLimit(2); Button("恢复窗口") { window.restore(); preview = false } }.padding(12) }.contextMenu { Button("恢复窗口") { window.restore() } }
    }
}
struct TrashTile:View {
    var size:Double
    @State private var full = false
    var body:some View {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent(".Trash")) } label: {
            let name = full ? "FullTrashIcon" : "TrashIcon"
            let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(name).icns"
            Image(nsImage:NSImage(contentsOfFile:path) ?? NSImage(systemSymbolName:full ? "trash.fill" : "trash",accessibilityDescription:"废纸篓")!).resizable().scaledToFit().frame(width:size,height:size).padding(3)
        }.buttonStyle(.plain).help("废纸篓").contextMenu {
            Button("打开废纸篓") { NSWorkspace.shared.open(URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent(".Trash")) }
            Button("清空废纸篓…") {
                let alert = NSAlert(); alert.messageText = "永久删除废纸篓中的所有项目？"; alert.informativeText = "这项操作无法撤销。"; alert.alertStyle = .warning; alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"清空废纸篓")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                var error:NSDictionary?; NSAppleScript(source:"tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
                if let error { AppStore.shared.errorMessage = error[NSAppleScript.errorMessage] as? String ?? "无法清空废纸篓。" }; refresh()
            }.disabled(!full)
        }.task {
            refresh()
            // A lightweight visible-only poll also handles external volume trash changes.
            while !Task.isCancelled { do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { return }; refresh() }
        }
    }
    private func refresh() { full = !((try? FileManager.default.contentsOfDirectory(atPath:NSHomeDirectory() + "/.Trash")) ?? []).isEmpty }
}
private struct DockSurface:View {
    let settings:DockSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var body:some View {
        if reduceTransparency || contrast == .increased { RoundedRectangle(cornerRadius:21).fill(settings.material == .dark ? Color.black : Color(nsColor:.windowBackgroundColor)) }
        else {
            #if compiler(>=6.2)
            if #available(macOS 26,*), settings.material == .liquidGlass { RoundedRectangle(cornerRadius:21).fill(.clear).glassEffect(settings.glassStyle == .clear ? .clear : .regular,in:RoundedRectangle(cornerRadius:21)) }
            else { fallback }
            #else
            fallback
            #endif
        }
    }
    @ViewBuilder private var fallback:some View { if settings.material == .dark { RoundedRectangle(cornerRadius:21).fill(Color.black.opacity(0.8)) } else if settings.material == .clear || settings.glassStyle == .clear { RoundedRectangle(cornerRadius:21).fill(.ultraThinMaterial) } else { RoundedRectangle(cornerRadius:21).fill(.regularMaterial) } }
}

private struct DockItemFramesKey:PreferenceKey { static var defaultValue:[UUID:CGRect] = [:]; static func reduce(value:inout [UUID:CGRect],nextValue:()->[UUID:CGRect]) { value.merge(nextValue(),uniquingKeysWith:{ _,new in new }) } }
