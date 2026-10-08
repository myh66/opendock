import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var restoreConfirmation = false
    private func binding<T>(_ key: WritableKeyPath<DockSettings, T>) -> Binding<T> { Binding(get: { store.settings[keyPath: key] }, set: { store.settings[keyPath: key] = $0 }) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 9) { Text("刚好合适你的桌面。").font(.system(size: 27, weight: .semibold)); Text("选择 Dock 的位置、外观与日常行为。").font(.system(size: 12)).foregroundStyle(DockTheme.secondary) }
                section("Dock 设置", symbol: "dock.rectangle") {
                    settingRow("显示自定义 Dock", detail: "与系统 Dock 同时使用。") { Toggle("", isOn: binding(\.showCustomDock)).labelsHidden().toggleStyle(.switch) }
                    Divider()
                    settingRow("屏幕位置") { Picker("", selection: binding(\.position)) { ForEach(DockPosition.allCases) { p in Text(p.title).tag(p) } }.labelsHidden().pickerStyle(.segmented).frame(width: 200) }
                    Divider()
                    settingRow("显示器") { Picker("", selection: binding(\.displayIndex)) { ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { entry in Text(entry.element.localizedName).tag(entry.offset) } }.labelsHidden().frame(width: 210) }
                    Divider()
                    settingRow("自动隐藏", detail: "将指针移动到屏幕边缘时显示。") { Toggle("", isOn: binding(\.autoHide)).labelsHidden().toggleStyle(.switch) }
                }
                section("外观", symbol: "paintbrush.pointed") {
                    settingRow("背景材质") { Picker("", selection: binding(\.material)) { ForEach(DockMaterial.allCases) { m in Text(m.title).tag(m) } }.labelsHidden().pickerStyle(.segmented).frame(width: 200) }
                    Divider()
                    settingRow("图标大小") { HStack { Slider(value: binding(\.iconSize), in: 24...80, step: 2).frame(width: 180); Text("\(Int(store.settings.iconSize))").font(.system(size: 11, design: .monospaced)).frame(width: 24) } }
                    Divider()
                    settingRow("悬停放大") { Toggle("", isOn: binding(\.magnification)).labelsHidden().toggleStyle(.switch) }
                    Divider()
                    settingRow("显示运行中的应用") { Toggle("", isOn: binding(\.showRunningApps)).labelsHidden().toggleStyle(.switch) }
                    Divider()
                    settingRow("显示废纸篓") { Toggle("", isOn: binding(\.showTrash)).labelsHidden().toggleStyle(.switch) }
                }
                section("系统与快捷键", symbol: "command") {
                    settingRow("登录时启动", detail: SMAppService.mainApp.status == .requiresApproval ? "请在系统设置中批准后台项目。" : "安装到 Applications 后可启用。") { Toggle("", isOn: Binding(get: { store.settings.launchAtLogin }, set: { store.setLaunchAtLogin($0) })).labelsHidden().toggleStyle(.switch) }
                    Divider()
                    settingRow("点击当前应用以最小化", detail: "需要辅助功能权限。") { Toggle("", isOn: binding(\.clickToMinimize)).labelsHidden().toggleStyle(.switch) }
                    Divider()
                    settingRow("辅助功能", detail: AppService.accessibilityEnabled ? "已授权，可操作应用窗口。" : "用于窗口切换和最小化，按需开启。") { Button(AppService.accessibilityEnabled ? "查看系统设置" : "允许…") { AppService.requestAccessibilityPermission() }.buttonStyle(QuietButtonStyle()) }
                    Divider()
                    settingRow("切换布局", detail: "按保存顺序切换前 9 个布局。") { Text("⌘ ⌥ 1 … 9").font(.system(size: 12, design: .monospaced)).foregroundStyle(DockTheme.accent) }
                }
                section("数据与恢复", symbol: "externaldrive") {
                    settingRow("布局备份", detail: "导入时追加布局，原有布局会保留。") { HStack { Button("导出") { store.exportArchive() }; Button("导入") { store.importArchive() } }.buttonStyle(QuietButtonStyle()) }
                    Divider()
                    settingRow("恢复系统 Dock", detail: "恢复上次应用系统布局前的固定应用。") { Button("恢复原布局…") { restoreConfirmation = true }.buttonStyle(QuietButtonStyle()).disabled(!store.nativeService.hasBackup || store.applyingNative) }
                    Divider()
                    settingRow("本地数据") { Button("在 Finder 中查看") { NSWorkspace.shared.activateFileViewerSelecting([store.storageURL]) }.buttonStyle(QuietButtonStyle()) }
                }
                if let profile = store.activeCustom {
                    section("自动化", symbol: "bolt") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("在快捷指令中使用「打开 URL」来切换当前自定义布局。可将快捷指令接入你自己的自动化。") .font(.system(size: 11)).foregroundStyle(DockTheme.secondary)
                            HStack { Text("opendock://profile/\(profile.id.uuidString)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(2); Spacer(); Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("opendock://profile/\(profile.id.uuidString)", forType: .string) } }.padding(12).background(DockTheme.canvas).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }.alert("恢复系统 Dock？", isPresented: $restoreConfirmation) { Button("取消", role: .cancel) {}; Button("恢复") { store.restoreNative() } } message: { Text("将重新启动系统 Dock，并恢复上次切换前固定的应用与分隔符。") }
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) { Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)); VStack(alignment: .leading, spacing: 15, content: content).padding(20).background(.white).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(DockTheme.line)) }
    }
    private func settingRow<Content: View>(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .medium)); if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(DockTheme.secondary) } }; Spacer(minLength: 15); content().font(.system(size: 11)) }
    }
}
