import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView:View {
    @EnvironmentObject var store:AppStore
    @ObservedObject private var windowMonitor = WindowMonitor.shared
    @ObservedObject private var updater = UpdateService.shared
    @State private var restoreConfirmation = false
    private func binding<T>(_ key:WritableKeyPath<DockSettings,T>)->Binding<T> { Binding(get:{ store.settings[keyPath:key] },set:{ store.settings[keyPath:key] = $0 }) }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:25) {
                VStack(alignment:.leading,spacing:9) { Text("刚好合适你的桌面。").font(.system(size:27,weight:.semibold)); Text("选择 Dock 的使用方式、外观与日常行为。").font(.system(size:12)).foregroundStyle(DockTheme.secondary) }
                section("使用方式",symbol:"dock.rectangle") {
                    settingRow("Dock 模式",detail:store.settings.mode == .replacement ? "运行期间隐藏 macOS Dock，退出时恢复原始隐藏设置。":"原生布局与自定义布局可以独立选择。") { Picker("Dock 模式",selection:binding(\.mode)) { ForEach(DockMode.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width:235) }
                    Divider()
                    settingRow("macOS 布局",detail:"选择后立即切换系统 Dock；「保留当前」停止关联保存的布局。") {
                        Picker("macOS 布局",selection:Binding<UUID?>(get:{store.archive.activeNativeID},set:{ id in if let id,let profile = store.profiles.first(where:{$0.id == id}) { store.activate(profile) } else { store.archive.activeNativeID = nil } })) { Text("保留当前").tag(Optional<UUID>.none); ForEach(store.profiles.filter { $0.kind == .native }) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden().frame(width:200)
                    }
                    Divider()
                    toggle("显示自定义 Dock",key:\.showCustomDock)
                    settingRow("自定义布局") { Picker("自定义布局",selection:Binding<UUID?>(get:{store.archive.activeCustomID},set:{ id in if let profile = store.profiles.first(where:{$0.id == id}) { store.activate(profile) } })) { ForEach(store.profiles.filter { $0.kind == .custom }) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden().frame(width:200) }
                    Divider()
                    toggle("自动保存 macOS 布局的变化",detail:"仅保存当前关联的原生布局，记录在系统 Dock 中手动固定、移除与排序的变化。",key:\.autoSaveNativeChanges)
                    toggle("平滑切换 macOS 布局",detail:"macOS 14 以上且已允许屏幕录制时，在重启期间保留桌面背景。",key:\.smoothNativeSwitch)
                }
                section("位置与行为",symbol:"rectangle.3.group") {
                    settingRow("屏幕位置") { Picker("屏幕位置",selection:binding(\.position)) { ForEach(DockPosition.allCases) { Text($0.title).tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(width:200) }
                    settingRow("显示器") { Picker("显示器",selection:binding(\.displayIndex)) { ForEach(Array(NSScreen.screens.enumerated()),id:\.offset) { Text($0.element.localizedName).tag($0.offset) } }.labelsHidden().frame(width:210) }
                    Divider()
                    toggle("自动隐藏",detail:"移到对应屏幕边缘显示；弹窗开启时保持显示。",key:\.autoHide)
                    if store.settings.autoHide { toggle("显示隐藏指示条",key:\.showHiddenHandle) }
                    toggle("为 Dock 留出窗口空间",detail:"通过辅助功能调整重叠的当前窗口；自动隐藏及桌面组件模式不调整窗口。",key:\.reserveWindowSpace)
                    toggle("作为桌面组件",detail:"放在应用窗口后方，适合日历、天气与便签。",key:\.desktopWidget)
                    if store.settings.mode == .both { toggle("macOS Dock 显示时隐藏",detail:"通过辅助功能读取系统 Dock 的可见位置。",key:\.hideWhenNativeDockShows) }
                }
                section("外观",symbol:"paintbrush.pointed") {
                    settingRow("背景材质") { Picker("背景材质",selection:binding(\.material)) { ForEach(DockMaterial.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width:180) }
                    if store.settings.material == .liquidGlass { settingRow("玻璃样式",detail:"macOS 26 以上使用系统 Liquid Glass；较早系统使用磨砂材质。") { Picker("玻璃样式",selection:binding(\.glassStyle)) { ForEach(GlassStyle.allCases) { Text($0.title).tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(width:150) } }
                    settingRow("图标大小",detail:"也可拖动 Dock 底部调整手柄。") { HStack { Slider(value:binding(\.iconSize),in:24...80,step:2).frame(width:160); Text("\(Int(store.settings.iconSize))").monospacedDigit().frame(width:25) } }
                    toggle("悬停放大",key:\.magnification)
                    toggle("运行中的应用",key:\.showRunningApps)
                    toggle("最小化窗口",detail:"需要辅助功能权限。已授权屏幕录制时保存窗口缩略图；关闭此项清理缓存。",key:\.showMinimizedWindows)
                    toggle("应用角标",detail:"读取系统 Dock 暴露的状态标签，需要辅助功能权限。",key:\.showBadges)
                    toggle("废纸篓",key:\.showTrash)
                    toggle("菜单栏显示当前布局名",key:\.showActiveNameInMenuBar)
                }
                section("权限与快捷键",symbol:"command") {
                    settingRow("登录时启动",detail:SMAppService.mainApp.status == .requiresApproval ? "请在系统设置中批准后台项目。":"安装到 Applications 后可启用。") { Toggle("登录时启动",isOn:Binding(get:{store.settings.launchAtLogin},set:{store.setLaunchAtLogin($0)})).labelsHidden().toggleStyle(.switch) }
                    toggle("点击当前应用以最小化",detail:"只操作当前空间的前台窗口，需要辅助功能权限。",key:\.clickToMinimize)
                    Divider()
                    settingRow("辅助功能",detail:AppService.accessibilityEnabled ? "已授权窗口操作。":"用于窗口切换、角标与窗口空间；按需开启。") { Button(AppService.accessibilityEnabled ? "查看系统设置":"允许…") { AppService.requestAccessibilityPermission() }.buttonStyle(QuietButtonStyle()) }
                    settingRow("屏幕录制",detail:windowMonitor.screenCaptureGranted ? "已授权窗口预览与平滑切换。":"用于窗口缩略图与平滑切换；读取不会主动请求权限。") { Button(windowMonitor.screenCaptureGranted ? "查看系统设置":"允许…") { windowMonitor.requestScreenCapturePermission() }.buttonStyle(QuietButtonStyle()) }
                    Divider()
                    ForEach(store.profiles) { profile in settingRow(profile.name) { ShortcutRecorder(profileID:profile.id) } }
                    Text("录制时至少使用两个修饰键。Escape 取消，Delete 清除。底部 Dock 上下滑动、侧边 Dock 左右滑动可切换布局；⌘ + 滚轮也可切换。").font(.system(size:10)).foregroundStyle(DockTheme.secondary)
                }
                section("专注模式与自动化",symbol:"moon") {
                    settingRow("专注模式过滤条件",detail:"系统设置 → 专注模式 → 添加过滤条件 → OpenDock → 选择布局。关闭专注模式时保留当前布局。") { Button("打开专注模式") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Focus-Settings.extension")!) }.buttonStyle(QuietButtonStyle()) }
                    settingRow("快捷指令",detail:"在快捷指令中搜索「切换 OpenDock 布局」，支持原生与自定义布局。") { Button("打开快捷指令") { NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Shortcuts.app")) }.buttonStyle(QuietButtonStyle()) }
                    if let profile = store.activeCustom {
                        HStack { Text("opendock://profile/\(profile.id.uuidString)").font(.system(size:10,design:.monospaced)).textSelection(.enabled); Spacer(); Button("复制 URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("opendock://profile/\(profile.id.uuidString)",forType:.string) } }.padding(12).background(DockTheme.canvas,in:RoundedRectangle(cornerRadius:8))
                    }
                }
                section("数据、更新与帮助",symbol:"externaldrive") {
                    settingRow("布局备份",detail:"导入追加布局；账号密钥保存在钥匙串，不包含在布局备份中。") { HStack { Button("导出") { store.exportArchive() }; Button("导入") { store.importArchive() } }.buttonStyle(QuietButtonStyle()) }
                    settingRow("恢复系统 Dock",detail:"恢复上次应用原生布局前的固定应用。") { Button("恢复原布局…") { restoreConfirmation = true }.buttonStyle(QuietButtonStyle()).disabled(!store.nativeService.hasBackup || store.applyingNative) }
                    settingRow("本地数据") { Button("在 Finder 中查看") { NSWorkspace.shared.activateFileViewerSelecting([store.storageURL]) }.buttonStyle(QuietButtonStyle()) }
                    Divider()
                    toggle("自动检查并下载更新",detail:"每天检查公开 GitHub Release，校验下载后由你点击安装。",key:\.automaticUpdateCheck)
                    settingRow("软件更新",detail:updater.state) { HStack { Button("检查更新") { Task { await updater.check(download:true) } }.disabled(updater.busy); if updater.readyApp != nil { Button("安装并重启") { updater.install() } } }.buttonStyle(QuietButtonStyle()) }
                    settingRow("使用引导") { Button("重新查看") { store.tourPresented = true }.buttonStyle(QuietButtonStyle()) }
                    settingRow("开源项目") { Link("GitHub",destination:URL(string:"https://github.com/myh66/opendock")!) }
                }
            }
        }.alert("恢复系统 Dock？",isPresented:$restoreConfirmation) { Button("取消",role:.cancel) {}; Button("恢复") { store.restoreNative() } } message: { Text("将重新启动系统 Dock，并恢复上次切换前固定的应用与分隔符。") }
    }
    private func toggle(_ title:String,detail:String? = nil,key:WritableKeyPath<DockSettings,Bool>)->some View { settingRow(title,detail:detail) { Toggle(title,isOn:binding(key)).labelsHidden().toggleStyle(.switch) } }
    private func section<Content:View>(_ title:String,symbol:String,@ViewBuilder content:()->Content)->some View { VStack(alignment:.leading,spacing:15) { Label(title,systemImage:symbol).font(.system(size:13,weight:.semibold)); VStack(alignment:.leading,spacing:15,content:content).padding(20).background(.white).clipShape(RoundedRectangle(cornerRadius:13)).overlay(RoundedRectangle(cornerRadius:13).stroke(DockTheme.line)) } }
    private func settingRow<Content:View>(_ title:String,detail:String? = nil,@ViewBuilder content:()->Content)->some View { HStack { VStack(alignment:.leading,spacing:5) { Text(title).font(.system(size:12,weight:.medium)); if let detail { Text(detail).font(.system(size:10)).foregroundStyle(DockTheme.secondary).fixedSize(horizontal:false,vertical:true) } }; Spacer(minLength:15); content().font(.system(size:11)) } }
}
