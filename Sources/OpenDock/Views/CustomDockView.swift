import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CustomDockView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var windows = WindowMonitor.shared
    @ObservedObject private var popovers = WidgetPopoverCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let openManager: () -> Void
    @State private var running: [DockItem] = []
    @State private var dragging: UUID?
    @State private var runningDrag: DockItem?
    @State private var contentLength: CGFloat = 0
    @State private var itemFrames:[UUID:CGRect] = [:]
    @State private var hoverTimer: Timer?
    @State private var resizeStart: Double?
    @State private var observedProfileID: UUID?
    @State private var displayedItemIDs: [UUID] = []
    @State private var highlightedItemID: UUID?
    @State private var feedbackTask: Task<Void, Never>?
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
                            }.dockScrollBounceBehavior().coordinateSpace(name:"DockScroll").onPreferenceChange(DockLengthKey.self) { contentLength = $0 }
                            .onPreferenceChange(DockItemFramesKey.self) { itemFrames = $0 }
                            if overflow {
                                if vertical { VStack { chevron(-1, proxy:proxy,profile:profile,viewport:vertical ? geometry.size.height:geometry.size.width); Spacer(); chevron(1,proxy:proxy,profile:profile,viewport:vertical ? geometry.size.height:geometry.size.width) } }
                                else { HStack { chevron(-1,proxy:proxy,profile:profile,viewport:vertical ? geometry.size.height:geometry.size.width); Spacer(); chevron(1,proxy:proxy,profile:profile,viewport:vertical ? geometry.size.height:geometry.size.width) } }
                            }
                        }
                        .onAppear { observedProfileID = profile.id; displayedItemIDs = profile.items.map(\.id); DockInteractionState.shared.contentOverflows = overflow }
                        .onChange(of: overflow) { DockInteractionState.shared.contentOverflows = $0 }
                        .onChange(of: profile.items.map(\.id)) { ids in showAddedItem(ids, profile: profile, proxy: proxy) }
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: profile.color)).frame(width: 4,height: 4)
                    Text(profile.name).font(.system(size: 9,weight: .medium)).lineLimit(1)
                    Button { store.settingsPresented = true; openManager() } label: { Image(systemName:"slider.horizontal.3").font(.system(size:10)) }.buttonStyle(.plain).help("设置")
                    Capsule().fill(.secondary.opacity(0.35)).frame(width: 18,height: 3).padding(5).help("拖动调整图标大小")
                        .gesture(DragGesture().onChanged { value in
                            if resizeStart == nil { resizeStart = store.settings.iconSize; DockInteractionState.shared.resizing = true; popovers.activeID = nil; hoverTimer?.invalidate() }
                            let delta = vertical ? -value.translation.width : -value.translation.height
                            store.settings.iconSize = min(80,max(24,(resizeStart ?? 44) + delta / 3))
                        }.onEnded { _ in resizeStart = nil; DockInteractionState.shared.resizing = false })
                }.foregroundStyle(.secondary).padding(.bottom,8)
            } else { Button("创建 Dock",action:openManager).padding(20) }
        }
        .background { DockSurface(settings:store.settings) }
        .clipShape(RoundedRectangle(cornerRadius:21))
        .overlay(RoundedRectangle(cornerRadius:21).stroke(contrast == .increased ? Color.primary.opacity(0.5) : .white.opacity(0.2),lineWidth:1))
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
        .onDisappear { hoverTimer?.invalidate(); feedbackTask?.cancel(); DockInteractionState.shared.resizing = false; DockInteractionState.shared.dragging = false; DockInteractionState.shared.contentOverflows = false }
        .onChange(of:store.archive.activeCustomID) { id in itemFrames = [:]; contentLength = 0; hoverTimer?.invalidate(); feedbackTask?.cancel(); highlightedItemID = nil; observedProfileID = id; displayedItemIDs = store.activeCustom?.items.map(\.id) ?? []; dragging = nil; runningDrag = nil; DockInteractionState.shared.dragging = false; popovers.activeID = nil }
        .onChange(of:popovers.activeID) { value in if value != nil { hoverTimer?.invalidate() } }
        .onChange(of:store.settings.position) { _ in itemFrames = [:]; contentLength = 0; hoverTimer?.invalidate(); feedbackTask?.cancel(); highlightedItemID = nil; popovers.activeID = nil }
        .onReceive(DockInteractionState.shared.$dragging) { active in if !active { dragging = nil; runningDrag = nil } }
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
            .overlay(RoundedRectangle(cornerRadius:14).stroke(DockTheme.accent.opacity(highlightedItemID == item.id ? 0.9 : 0),lineWidth:2).padding(-2).allowsHitTesting(false))
            .onDrag { dragging = item.id; runningDrag = nil; popovers.activeID = nil; DockInteractionState.shared.dragging = true; return DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[item.id]).itemProvider }
            .onDrop(of:DockDragPayload.acceptedTypes,delegate:DockDropDelegate(targetID:item.id,profileID:profile.id,unpin:false,dragged:$dragging,running:$runningDrag,store:store))
        }
        Color.clear.frame(width:vertical ? 34 : 6,height:vertical ? 6 : 34)
            .onDrop(of:DockDragPayload.acceptedTypes,delegate:DockDropDelegate(targetID:nil,profileID:profile.id,unpin:false,dragged:$dragging,running:$runningDrag,store:store))
        if !runningExtras.isEmpty || store.settings.showMinimizedWindows {
            divider
            ForEach(runningExtras) { item in
                DockLauncher(item:item,profileID:profile.id,pinned:false).environmentObject(store).id(item.id).background(itemGeometry(item.id))
                    .onDrag { dragging = item.id; runningDrag = item; popovers.activeID = nil; DockInteractionState.shared.dragging = true; return DockDragPayload(sourceProfileID:profile.id,orderedItemIDs:[item.id],runningItem:item).itemProvider }
                    .onDrop(of:DockDragPayload.acceptedTypes,delegate:DockDropDelegate(targetID:nil,profileID:profile.id,unpin:true,dragged:$dragging,running:$runningDrag,store:store))
            }
            if store.settings.showMinimizedWindows { ForEach(windows.minimized) { window in MinimizedWindowTile(window:window,size:store.settings.iconSize,position:store.settings.position).id(window.id) } }
            Color.clear.frame(width:vertical ? 34 : 6,height:vertical ? 6 : 34)
                .onDrop(of:DockDragPayload.acceptedTypes,delegate:DockDropDelegate(targetID:nil,profileID:profile.id,unpin:true,dragged:$dragging,running:$runningDrag,store:store))
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
            withAnimation(reduceMotion ? nil : .easeOut(duration:0.16)) { proxy.scrollTo(ids[next],anchor:.center) }
        }
        return Button(action:advance) { Image(systemName: vertical ? (direction < 0 ? "chevron.up" : "chevron.down") : (direction < 0 ? "chevron.left" : "chevron.right")).font(.system(size:10,weight:.bold)).frame(width:28,height:28).dockGlass(cornerRadius:14) }
            .buttonStyle(.plain).padding(3).onHover { inside in hoverTimer?.invalidate(); if inside && popovers.activeID == nil { hoverTimer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { _ in Task { @MainActor in advance() } } } }
            .onDisappear { hoverTimer?.invalidate() }
    }
    private func itemGeometry(_ id:UUID)->some View { GeometryReader { proxy in Color.clear.preference(key:DockItemFramesKey.self,value:[id:proxy.frame(in:.named("DockScroll"))]) } }
    private func refreshRunning() { running = AppService.runningApps() }
    private func showAddedItem(_ ids:[UUID],profile:DockProfile,proxy:ScrollViewProxy) {
        guard observedProfileID == profile.id else { observedProfileID = profile.id; displayedItemIDs = ids; return }
        let old = Set(displayedItemIDs); displayedItemIDs = ids
        guard let added = ids.last(where: { !old.contains($0) }) else { return }
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor in
            // Wait for the new tile's layout before asking ScrollViewReader to reveal it.
            try? await Task.sleep(nanoseconds:120_000_000)
            guard !Task.isCancelled, store.archive.activeCustomID == profile.id else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration:0.22)) { proxy.scrollTo(added,anchor:.center); highlightedItemID = added }
            try? await Task.sleep(nanoseconds:1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration:0.2)) { highlightedItemID = nil }
        }
    }
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
    func dropEntered(info:DropInfo) { guard !unpin, running == nil, let id = dragged, let targetID else { return }; store.moveItems([id],to:targetID,in:profileID) }
    func dropUpdated(info:DropInfo)->DropProposal? { DropProposal(operation:dragged == nil || running != nil ? .copy : .move) }
    func performDrop(info:DropInfo)->Bool {
        let localID = dragged, localRunning = running
        defer { dragged = nil; running = nil; DockInteractionState.shared.dragging = false }
        if let localID {
            return apply(DockDragPayload(sourceProfileID:profileID,orderedItemIDs:[localID],runningItem:localRunning),hoverAlreadyMoved:localRunning == nil && targetID != nil)
        }
        let providers = info.itemProviders(for:DockDragPayload.acceptedTypes)
        guard !providers.isEmpty else { return false }
        DockDragPayload.load(from:providers,profiles:store.profiles) { payload in
            if let payload { _ = apply(payload,hoverAlreadyMoved:false) }
        }
        return true
    }
    @MainActor private func apply(_ payload:DockDragPayload,hoverAlreadyMoved:Bool)->Bool {
        guard store.profiles.contains(where:{$0.id == profileID && $0.kind == .custom}),
              let items = payload.resolvedItems(in:store.profiles) else { return false }
        let ids = Set(items.map(\.id))
        if unpin {
            guard payload.sourceProfileID == profileID,payload.runningItem == nil,items.allSatisfy({$0.kind == .app}) else { return false }
            store.removeItems(ids,from:profileID)
        } else if payload.runningItem != nil || payload.sourceProfileID != profileID {
            let copies = items.map(AppStore.independentCopy)
            store.addItems(copies,to:profileID); store.moveItems(Set(copies.map(\.id)),to:targetID,in:profileID)
        } else if !hoverAlreadyMoved { store.moveItems(ids,to:targetID,in:profileID) }
        return true
    }
}

struct DockLauncher: View {
    @EnvironmentObject var store:AppStore
    @ObservedObject private var windows = WindowMonitor.shared
    @ObservedObject private var coordinator = WidgetPopoverCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item:DockItem; let profileID:UUID; var pinned = true
    @State private var hovered = false
    @State private var browse = false
    @State private var contents:[DockItem] = []
    @State private var hold:Task<Void,Never>?
    @State private var thumbnail:NSImage?
    var body:some View {
        Button {
            if item.kind == .appGroup { if !browse { NSApp.activate(ignoringOtherApps:true); loadContents() }; browse.toggle() }
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
            withAnimation(reduceMotion ? nil : .easeOut(duration:0.12)) { hovered = inside }
            hold?.cancel()
            if inside && item.kind == .folder && coordinator.activeID == nil && !DockInteractionState.shared.dragging && !DockInteractionState.shared.resizing {
                hold = Task { try? await Task.sleep(nanoseconds:700_000_000); guard !Task.isCancelled, hovered, coordinator.activeID == nil, !DockInteractionState.shared.dragging, !DockInteractionState.shared.resizing else { return }; loadContents(); browse = true }
            }
        }
        .task(id:item.target) { thumbnail = nil; if item.kind == .file { thumbnail = await FilePreviewService.shared.thumbnail(for:URL(fileURLWithPath:item.target),size:CGSize(width:80,height:80)) } }
        .popover(isPresented:$browse,arrowEdge:store.settings.position.popoverEdge) {
            ScrollView {
                VStack(alignment:.leading,spacing:9) {
                    HStack {
                        AppIconView(item:item,size:24)
                        Text(item.title).font(.headline).lineLimit(2)
                        Spacer()
                        Button { browse = false } label: { Image(systemName:"xmark").font(.system(size:11,weight:.semibold)).frame(width:32,height:32) }.buttonStyle(.plain).dockGlass(cornerRadius:16).help("关闭").accessibilityLabel("关闭内容浏览")
                    }
                    if contents.isEmpty { Text("这里暂时没有可显示的项目。").foregroundStyle(.secondary) }
                    ForEach(contents) { child in
                        Button { browse = false; AppService.open(child) } label: { HStack { AppIconView(item:child,size:24); Text(child.title).lineLimit(1); Spacer() }.padding(7).contentShape(RoundedRectangle(cornerRadius:9)) }
                            .buttonStyle(.plain)
                            .onDrag {
                                DockInteractionState.shared.dragging = true
                                if child.kind == .app { return DockDragPayload(sourceProfileID:profileID,orderedItemIDs:[child.id],runningItem:child).itemProvider }
                                return NSItemProvider(contentsOf:URL(fileURLWithPath:child.target)) ?? NSItemProvider(object:child.target as NSString)
                            }
                            .contextMenu {
                                if child.kind == .file { Button("快速查看") { FilePreviewService.shared.showQuickLook([URL(fileURLWithPath:child.target)]) } }
                                Button("在 Finder 中显示") { AppService.reveal(child) }
                                if child.kind == .app { Button("保留在 Dock 中") { store.addItems([AppStore.independentCopy(child)],to:profileID); browse = false } }
                            }
                    }
                }.padding(18)
            }.frame(width:300,height:min(CGFloat(contents.count * 42 + 90),400)).dockCard(cornerRadius:20).onExitCommand { browse = false }
        }
        .onChange(of:browse) { open in if open { coordinator.activeID = item.id } else if coordinator.activeID == item.id { coordinator.activeID = nil } }
        .onChange(of:coordinator.activeID) { active in if active != item.id { browse = false } }
        .onChange(of:item.configuration) { _ in if browse { loadContents() } }
        .onChange(of:item.target) { _ in if browse { loadContents() } }
        .onDisappear { hold?.cancel(); if coordinator.activeID == item.id { coordinator.activeID = nil } }
        .contextMenu {
            Button("打开") { AppService.open(item) }
            if item.kind == .folder || item.kind == .appGroup { Button("浏览内容") { NSApp.activate(ignoringOtherApps:true); loadContents(); browse = true } }
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
        contents = []
        if item.kind == .appGroup {
            if let data = item.configuration["apps"]?.data(using:.utf8), let apps = try? JSONDecoder().decode([DockItem].self,from:data) { contents = apps.filter { $0.kind == .app } }
            else if let data = item.target.data(using:.utf8), let paths = try? JSONDecoder().decode([String].self,from:data) { contents = paths.map { DockItem(kind:.app,title:URL(fileURLWithPath:$0).deletingPathExtension().lastPathComponent,target:$0) } }
        } else {
            let urls = (try? FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:item.target),includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])) ?? []
            contents = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map { url in DockItem(kind:url.pathExtension.lowercased() == "app" ? .app : (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true ? .folder : .file,title:url.lastPathComponent,target:url.path) }
        }
    }
}
private struct MinimizedWindowTile:View {
    @EnvironmentObject private var store:AppStore
    @ObservedObject private var coordinator = WidgetPopoverCoordinator.shared
    let window:MiniWindow; let size:Double; let position:DockPosition
    @State private var preview = false
    @State private var popoverID = UUID()
    @State private var hoverTask:Task<Void,Never>?
    var body:some View {
        Button(action:restore) {
            ZStack(alignment:.bottomTrailing) {
                if let image = window.image { Image(nsImage:image).resizable().scaledToFit().frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:6)) }
                else { Image(systemName:"macwindow").font(.system(size:size * 0.5)).frame(width:size,height:size) }
                AppIconView(item:window.appItem,size:18)
            }.padding(3)
        }.buttonStyle(.plain).help(window.title)
        .onHover { inside in
            hoverTask?.cancel()
            if inside, !preview, coordinator.activeID == nil {
                hoverTask = Task { try? await Task.sleep(nanoseconds:350_000_000); guard !Task.isCancelled, coordinator.activeID == nil, !DockInteractionState.shared.dragging else { return }; preview = true }
            }
        }
        .popover(isPresented:$preview,arrowEdge:position.popoverEdge) {
            VStack(spacing:12) {
                HStack { Text(window.title).font(.headline).lineLimit(2); Spacer(); Button { preview = false } label: { Image(systemName:"xmark").frame(width:32,height:32) }.buttonStyle(.plain).dockGlass(cornerRadius:16).help("关闭") }
                if let image = window.image { Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:320,maxHeight:220) }
                Button("恢复窗口",action:restore)
            }.padding(16).frame(maxWidth:350).dockCard(cornerRadius:20).onExitCommand { preview = false }
        }
        .onChange(of:preview) { open in if open { coordinator.activeID = popoverID } else if coordinator.activeID == popoverID { coordinator.activeID = nil } }
        .onChange(of:coordinator.activeID) { active in if active != popoverID { preview = false } }
        .onDisappear { hoverTask?.cancel(); if coordinator.activeID == popoverID { coordinator.activeID = nil } }
        .contextMenu { Button("恢复窗口",action:restore) }
    }
    private func restore() { hoverTask?.cancel(); preview = false; if coordinator.activeID == popoverID { coordinator.activeID = nil }; if !window.restore() { store.errorMessage = "无法恢复窗口。窗口可能已关闭，或辅助功能权限已撤销。" } }
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

private extension DockPosition {
    var popoverEdge:Edge { switch self { case .bottom:return .bottom;case .left:return .leading;case .right:return .trailing } }
}

private extension View {
    @ViewBuilder func dockScrollBounceBehavior()->some View {
        if #available(macOS 13.3,*) { scrollBounceBehavior(.basedOnSize,axes:[.horizontal,.vertical]) }
        else { background(DockLegacyScrollBehavior()) }
    }
}

/// SwiftUI added size-aware bounce in macOS 13.3. Older macOS keeps scrolling
/// enabled while disabling rubber-band motion through the public NSScrollView API.
private struct DockLegacyScrollBehavior:NSViewRepresentable {
    func makeNSView(context:Context)->NSView { let view = NSView(); configure(view); return view }
    func updateNSView(_ view:NSView,context:Context) { configure(view) }
    private func configure(_ view:NSView) {
        DispatchQueue.main.async {
            if let scroll = view.enclosingScrollView { scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none }
        }
    }
}
