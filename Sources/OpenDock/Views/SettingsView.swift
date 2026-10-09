import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var windowMonitor = WindowMonitor.shared
    @ObservedObject private var updater = UpdateService.shared
    @State private var restoreConfirmation = false
    @State private var accessibilityGranted = AppService.accessibilityEnabled
    @State private var captureGranted = false
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var screens = NSScreen.screens
    @State private var copiedURL = false

    private var customVisible: Bool { store.settings.mode != .nativeOnly && store.settings.showCustomDock }
    private var nativeProfiles: [DockProfile] { store.profiles.filter { $0.kind == .native } }
    private var customProfiles: [DockProfile] { store.profiles.filter { $0.kind == .custom } }
    private var supportsSmoothSwitch: Bool { if #available(macOS 14, *) { return true }; return false }
    private var release: String { Bundle.main.infoDictionary?["OpenDockReleaseTag"] as? String ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版" }
    private var windowSpaceHint: String {
        if !customVisible { return "显示自定义 Dock 后可用。" }
        if store.settings.autoHide { return "自动隐藏时让窗口使用完整屏幕。" }
        if store.settings.desktopWidget { return "桌面组件放在窗口后方，无需预留空间。" }
        return accessibilityGranted ? "重叠的当前窗口会为 Dock 留出空间。" : "需要下方的辅助功能权限，用于调整重叠的当前窗口。"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                setupSection
                appearanceSection
                positionSection
                behaviorSection
                itemsSection
                permissionsSection
                shortcutsSection
                automationSection
                dataSection
                updateSection
                helpSection
            }
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 28)
        }
        .tint(DockTheme.accent)
        .onAppear(perform: refreshSystemState)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in screens = NSScreen.screens }
        .onChange(of: store.archive.activeCustomID) { _ in copiedURL = false }
        .alert("恢复系统 Dock？", isPresented: $restoreConfirmation) {
            Button("取消", role: .cancel) {}
            Button("恢复") { store.restoreNative() }
        } message: {
            Text("将重新启动系统 Dock，恢复上次应用原生布局前固定的应用与分隔符。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让桌面按你的习惯工作。")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("布局、外观与日常操作，都在这里调整。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                statusBadge(modeTitle(store.settings.mode), symbol: "dock.rectangle", color: DockTheme.accent)
                if customVisible { statusBadge(store.settings.position.title, symbol: "display", color: .secondary) }
                if store.applyingNative { statusBadge("正在切换系统 Dock", symbol: "arrow.triangle.2.circlepath", color: DockTheme.accent) }
            }
        }.padding(.bottom, 2)
    }

    private var setupSection: some View {
        section("Dock 使用方式", symbol: "dock.rectangle", detail: "原生布局和自定义布局分别保存。") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(DockMode.allCases) { mode in
                    optionCard(modeTitle(mode), detail: modeDetail(mode), selected: store.settings.mode == mode) {
                        SettingsModePreview(mode: mode)
                    } action: { selectMode(mode) }
                }
            }
            if store.settings.mode == .replacement {
                contextualHint("运行期间隐藏 macOS Dock；关闭此模式或退出时恢复原来的隐藏设置。", symbol: "arrow.uturn.backward")
            }
            Divider().padding(.vertical, 2)
            settingRow("macOS 布局", detail: "选择后立即应用并重启系统 Dock。") {
                Picker("macOS 布局", selection: Binding<UUID?>(get: { store.archive.activeNativeID }, set: { id in
                    if let id, let profile = nativeProfiles.first(where: { $0.id == id }) { store.activate(profile) }
                    else { store.archive.activeNativeID = nil }
                })) {
                    Text("保留当前系统布局").tag(Optional<UUID>.none)
                    ForEach(nativeProfiles) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 225).disabled(store.applyingNative)
            }
            toggle("显示自定义 Dock", detail: store.settings.mode == .nativeOnly ? "选择「并用」或「自定义为主」后可显示。" : store.settings.mode == .replacement ? "主 Dock 模式保持显示，可以使用下方的自动隐藏。" : "保留布局与设置，随时显示或隐藏。", key: \.showCustomDock, disabled: store.settings.mode == .nativeOnly || (store.settings.mode == .replacement && store.settings.showCustomDock))
            settingRow("自定义布局", detail: customProfiles.isEmpty ? "先在布局页创建一个自定义 Dock。" : "切换布局会显示自定义 Dock。") {
                Picker("自定义布局", selection: Binding<UUID?>(get: { store.archive.activeCustomID }, set: { id in
                    if let profile = customProfiles.first(where: { $0.id == id }) { store.activate(profile) }
                })) {
                    if store.archive.activeCustomID == nil { Text("尚未选择").tag(Optional<UUID>.none) }
                    ForEach(customProfiles) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 225).disabled(customProfiles.isEmpty)
            }
            Divider().padding(.vertical, 2)
            toggle("自动保存系统布局变化", detail: store.archive.activeNativeID == nil ? "关联一个 macOS 布局后可用。" : "将手动固定、移除和排序的变化保存到当前 macOS 布局。", key: \.autoSaveNativeChanges, disabled: store.archive.activeNativeID == nil)
            toggle("平滑切换系统布局", detail: supportsSmoothSwitch ? "已允许屏幕录制时，在 Dock 重启期间保留桌面背景。" : "需要 macOS 14 或更高版本。", key: \.smoothNativeSwitch, disabled: !supportsSmoothSwitch)
        }
    }

    private var appearanceSection: some View {
        section("外观与材质", symbol: "paintpalette", detail: "为 Dock 选一种合适的质感。") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                ForEach(DockMaterial.allCases) { material in
                    optionCard(material.title, detail: materialDetail(material), selected: store.settings.material == material) {
                        SettingsMaterialPreview(material: material)
                    } action: { store.settings.material = material }
                }
            }
            if store.settings.material == .liquidGlass {
                settingRow("玻璃样式", detail: glassAvailabilityHint) {
                    Picker("玻璃样式", selection: binding(\.glassStyle)) {
                        ForEach(GlassStyle.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }
            }
            toggle("悬停放大", detail: "指针经过时轻轻放大；跟随系统减少动态效果设置。", key: \.magnification)
        }
    }

    private var positionSection: some View {
        section("位置与尺寸", symbol: "display", detail: customVisible ? "调整当前自定义 Dock。" : "设置会保留，下次显示自定义 Dock 时生效。") {
            settingRow("屏幕位置") {
                DockGlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(DockPosition.allCases) { position in
                            Button { store.settings.position = position } label: {
                                Label(position.title, systemImage: positionSymbol(position)).font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .dockGlass(cornerRadius: 12, tint: store.settings.position == position ? DockTheme.accent.opacity(0.16) : nil, interactive: true)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.settings.position == position ? DockTheme.accent.opacity(0.65) : Color.clear))
                            }.buttonStyle(.plain).accessibilityAddTraits(store.settings.position == position ? .isSelected : [])
                        }
                    }
                }
            }
            settingRow("显示器", detail: screens.indices.contains(store.settings.displayIndex) ? nil : "目标显示器未连接，暂时使用可用显示器。") {
                Picker("显示器", selection: binding(\.displayIndex)) {
                    if !screens.indices.contains(store.settings.displayIndex) { Text("显示器 \(store.settings.displayIndex + 1) · 未连接").tag(store.settings.displayIndex) }
                    ForEach(Array(screens.enumerated()), id: \.offset) { Text($0.element.localizedName).tag($0.offset) }
                }.labelsHidden().frame(width: 225)
            }
            settingRow("图标大小", detail: "也可以直接拖动 Dock 的尺寸手柄。") {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
                    Slider(value: binding(\.iconSize), in: 24...80, step: 2).frame(width: 150).accessibilityLabel("Dock 图标大小")
                    Text("\(Int(store.settings.iconSize)) pt").font(.system(size: 12, design: .monospaced)).frame(width: 45, alignment: .trailing)
                }
            }
        }
    }

    private var behaviorSection: some View {
        section("显示与窗口", symbol: "macwindow", detail: "让 Dock 与桌面上的窗口自然配合。") {
            toggle("自动隐藏", detail: "移到屏幕边缘显示，打开弹窗时保持可见。", key: \.autoHide, disabled: !customVisible)
            toggle("显示隐藏指示条", detail: "自动隐藏时，在屏幕边缘保留一个小提示。", key: \.showHiddenHandle, disabled: !customVisible || !store.settings.autoHide)
            Divider().padding(.vertical, 2)
            toggle("作为桌面组件", detail: "留在应用窗口后方，适合日历、天气与便签。", key: \.desktopWidget, disabled: !customVisible)
            toggle("为 Dock 留出窗口空间", detail: windowSpaceHint, key: \.reserveWindowSpace, disabled: !customVisible || store.settings.autoHide || store.settings.desktopWidget)
            toggle("macOS Dock 出现时让位", detail: store.settings.mode == .both ? "需要辅助功能权限，跟随系统 Dock 的可见位置。" : "在「并用」模式下可用。", key: \.hideWhenNativeDockShows, disabled: !customVisible || store.settings.mode != .both)
        }
    }

    private var itemsSection: some View {
        section("应用与内容", symbol: "square.grid.2x2", detail: "选择 Dock 中出现的项目和操作。") {
            toggle("运行中的应用", detail: "在固定项目旁显示正在运行的应用。", key: \.showRunningApps, disabled: !customVisible)
            toggle("最小化窗口", detail: "需要辅助功能权限；允许屏幕录制后缓存缩略图，关闭时清理缓存。", key: \.showMinimizedWindows, disabled: !customVisible)
            toggle("应用角标", detail: "通过辅助功能读取系统 Dock 的状态标签。", key: \.showBadges, disabled: !customVisible)
            toggle("点击当前应用以最小化", detail: "仅操作当前空间的前台窗口，需要辅助功能权限。", key: \.clickToMinimize, disabled: !customVisible)
            toggle("废纸篓", detail: "从 Dock 打开废纸篓，清空前仍会确认。", key: \.showTrash, disabled: !customVisible)
            Divider().padding(.vertical, 2)
            toggle("菜单栏显示布局名称", detail: "快速确认当前正在使用的布局。", key: \.showActiveNameInMenuBar)
        }
    }

    private var permissionsSection: some View {
        section("系统权限与启动", symbol: "lock.shield", detail: "只有点击允许时才请求相关权限。") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                permissionCard("辅助功能", symbol: "hand.point.up.left", allowed: accessibilityGranted, detail: "用于窗口操作、角标与窗口空间。") {
                    AppService.requestAccessibilityPermission(); refreshSystemState()
                }
                permissionCard("屏幕录制", symbol: "rectangle.dashed.badge.record", allowed: captureGranted, detail: "用于窗口缩略图与平滑 Dock 切换。") {
                    windowMonitor.requestScreenCapturePermission(); refreshSystemState()
                }
            }
            Divider().padding(.vertical, 2)
            settingRow("登录时启动", detail: loginHint) {
                Toggle("登录时启动", isOn: Binding(get: { store.settings.launchAtLogin }, set: { value in
                    store.setLaunchAtLogin(value); loginStatus = SMAppService.mainApp.status
                })).labelsHidden().toggleStyle(.switch)
            }
            if loginStatus == .requiresApproval {
                Button("在系统设置中批准登录项目") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var shortcutsSection: some View {
        section("布局快捷键", symbol: "command", detail: "点选一个快捷键，按下至少两个修饰键与一个按键。") {
            ForEach(ProfileKind.allCases) { kind in
                let profiles = store.profiles.filter { $0.kind == kind }
                if !profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(kind.title, systemImage: kind.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(profiles) { profile in settingRow(profile.name) { ShortcutRecorder(profileID: profile.id) } }
                    }
                    if kind == .custom && !nativeProfiles.isEmpty { Divider().padding(.vertical, 2) }
                }
            }
            contextualHint("Escape 取消录制，Delete 清除。底部 Dock 上下滑动、侧边 Dock 左右滑动可切换布局；⌘ + 滚轮也可切换。", symbol: "hand.draw")
        }
    }

    private var automationSection: some View {
        section("专注与自动化", symbol: "moon", detail: "让布局跟随工作场景切换。") {
            settingRow("专注模式过滤条件", detail: "系统设置 → 专注模式 → 添加过滤条件 → OpenDock。结束专注后保留当前布局。") {
                Button("打开专注模式") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { NSWorkspace.shared.open(url) }
                }.buttonStyle(QuietButtonStyle())
            }
            settingRow("快捷指令", detail: "搜索「切换 OpenDock 布局」，支持原生与自定义布局。") {
                Button("打开快捷指令") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }.buttonStyle(QuietButtonStyle())
            }
            if let profile = store.activeCustom {
                Divider().padding(.vertical, 2)
                settingRow("当前布局的链接", detail: "在自动化中打开此链接，切换到「\(profile.name)」。") {
                    Button(copiedURL ? "已复制" : "复制链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("opendock://profile/\(profile.id.uuidString)", forType: .string)
                        copiedURL = true
                    }.buttonStyle(QuietButtonStyle())
                }
                Text("opendock://profile/\(profile.id.uuidString)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var dataSection: some View {
        section("备份与本地数据", symbol: "externaldrive", detail: "布局保存在本机，可随时导出备份。") {
            settingRow("布局备份", detail: "导入会追加布局。账号密钥保存在钥匙串，不包含在备份中。") {
                DockGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("导入") { store.importArchive() }
                        Button("导出") { store.exportArchive() }
                    }.buttonStyle(QuietButtonStyle())
                }
            }
            settingRow("恢复系统 Dock", detail: store.nativeService.hasBackup ? "恢复上次应用原生布局前的固定应用与分隔符。" : "应用过原生布局后，可恢复上一次备份。") {
                Button("恢复原布局…") { restoreConfirmation = true }.buttonStyle(QuietButtonStyle())
                    .disabled(!store.nativeService.hasBackup || store.applyingNative)
            }
            settingRow("本地数据", detail: "查看布局文件及所在文件夹。") {
                Button("在 Finder 中查看") { NSWorkspace.shared.activateFileViewerSelecting([store.storageURL]) }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var updateSection: some View {
        section("软件更新", symbol: "arrow.down.circle", detail: "当前版本 \(release)") {
            toggle("自动检查并下载", detail: "每天检查 GitHub Release；校验下载后由你点击安装。", key: \.automaticUpdateCheck)
            Divider().padding(.vertical, 2)
            settingRow(updater.readyApp != nil ? "更新已准备好" : updater.busy ? "正在检查更新" : "更新状态", detail: updater.state) {
                DockGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        if updater.busy { ProgressView().controlSize(.small) }
                        Button("检查并下载") { Task { await updater.check(download: true) } }.buttonStyle(QuietButtonStyle()).disabled(updater.busy)
                        if updater.readyApp != nil {
                            Button("安装并重启") { updater.install() }.buttonStyle(DockGlassButtonStyle(prominent: true)).disabled(updater.busy)
                        }
                    }
                }
            }
        }
    }

    private var helpSection: some View {
        section("帮助与开源", symbol: "questionmark.circle") {
            settingRow("使用引导", detail: "重新了解布局、组件与 Dock 使用方式。") {
                Button("重新查看") { store.tourPresented = true }.buttonStyle(QuietButtonStyle())
            }
            settingRow("OpenDock 开源项目", detail: "使用 MIT 许可，反馈问题或参与改进。") {
                Link(destination: URL(string: "https://github.com/myh66/opendock")!) { Label("GitHub", systemImage: "arrow.up.right") }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private func binding<T>(_ key: WritableKeyPath<DockSettings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: key] }, set: { store.settings[keyPath: key] = $0 })
    }
    private func toggle(_ title: String, detail: String? = nil, key: WritableKeyPath<DockSettings, Bool>, disabled: Bool = false) -> some View {
        settingRow(title, detail: detail, dimmed: disabled) {
            Toggle(title, isOn: binding(key)).labelsHidden().toggleStyle(.switch).disabled(disabled)
        }
    }
    private func section<Content: View>(_ title: String, symbol: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(DockTheme.accent).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            content()
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).dockCard(cornerRadius: 22)
    }
    private func settingRow<Content: View>(_ title: String, detail: String? = nil, dimmed: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 22) {
                rowLabel(title, detail: detail).frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                content().font(.system(size: 12)).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 11) {
                rowLabel(title, detail: detail)
                content().font(.system(size: 12))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.opacity(dimmed ? 0.58 : 1)
    }
    private func rowLabel(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func optionCard<Preview: View>(_ title: String, detail: String, selected: Bool, @ViewBuilder preview: () -> Preview, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                preview().frame(height: 65).frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? DockTheme.accent : Color.secondary.opacity(0.35)).font(.system(size: 14))
                }
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2).frame(height: 28, alignment: .top)
            }.padding(13).frame(maxWidth: .infinity)
                .dockGlass(cornerRadius: 16, tint: selected ? DockTheme.accent.opacity(0.12) : nil, interactive: true)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? DockTheme.accent.opacity(0.65) : Color.secondary.opacity(0.1), lineWidth: selected ? 1.5 : 1))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected ? "已选择" : "未选择").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func permissionCard(_ title: String, symbol: String, allowed: Bool, detail: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 5)
                Image(systemName: allowed ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(allowed ? Color.green : Color.secondary)
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(allowed ? "已允许" : "尚未允许").font(.system(size: 11, weight: .medium)).foregroundStyle(allowed ? Color.green : Color.secondary)
                Spacer()
                Button(allowed ? "查看设置" : "允许…", action: action).buttonStyle(QuietButtonStyle())
            }
        }.padding(15).dockCard(cornerRadius: 16)
    }
    private func statusBadge(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6).dockGlass(cornerRadius: 20)
    }
    private func contextualHint(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(.secondary)
    }
    private func refreshSystemState() {
        accessibilityGranted = AppService.accessibilityEnabled
        captureGranted = windowMonitor.screenCaptureGranted
        loginStatus = SMAppService.mainApp.status
    }
    private func selectMode(_ mode: DockMode) {
        var settings = store.settings
        settings.mode = mode
        if mode == .replacement { settings.showCustomDock = true }
        store.settings = settings
    }
    private var loginHint: String {
        switch loginStatus {
        case .enabled: return "已注册，登录这台 Mac 时自动打开。"
        case .requiresApproval: return "已注册，等待你在系统设置中批准。"
        case .notFound: return "请先将完整应用安装到 Applications。"
        case .notRegistered: return "登录后自动打开 OpenDock。"
        @unknown default: return "登录项目状态由系统管理。"
        }
    }
    private var glassAvailabilityHint: String {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return "使用系统 Liquid Glass，跟随系统辅助显示设置。" }
        #endif
        return "当前系统或构建工具使用磨砂回退，玻璃选项会保留。"
    }
    private func modeTitle(_ mode: DockMode) -> String {
        switch mode { case .nativeOnly: return "macOS Dock"; case .both: return "两者并用"; case .replacement: return "自定义为主" }
    }
    private func modeDetail(_ mode: DockMode) -> String {
        switch mode {
        case .nativeOnly: return "保存和切换系统布局。"
        case .both: return "保留系统 Dock，搭配组件。"
        case .replacement: return "自定义 Dock 接管日常操作。"
        }
    }
    private func materialDetail(_ material: DockMaterial) -> String {
        switch material { case .frosted: return "轻柔模糊，内容清晰。"; case .dark: return "深色背景，安静聚焦。"; case .clear: return "更通透，融入桌面。"; case .liquidGlass: return "随背景变化的系统玻璃。" }
    }
    private func positionSymbol(_ position: DockPosition) -> String {
        switch position { case .left: return "sidebar.left"; case .bottom: return "dock.rectangle"; case .right: return "sidebar.right" }
    }
}

private struct SettingsModePreview: View {
    let mode: DockMode
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: [DockTheme.accent.opacity(0.1), Color.cyan.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.15))
            if mode != .replacement {
                HStack(spacing: 3) { ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(index == 2 ? 0.55 : 0.3)).frame(width: 9, height: 9) } }
                    .padding(5).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7)).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 7)
            }
            if mode != .nativeOnly {
                VStack(spacing: 3) { ForEach(0..<3) { index in RoundedRectangle(cornerRadius: 3).fill(DockTheme.accent.opacity(index == 1 ? 0.85 : 0.5)).frame(width: 10, height: index == 1 ? 15 : 10) } }
                    .padding(5).background(DockTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7)).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 8)
            }
        }.frame(width: 125, height: 65).accessibilityHidden(true)
    }
}

private struct SettingsMaterialPreview: View {
    let material: DockMaterial
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color(hex: "A3D9D3"), Color(hex: "B4AEED"), Color(hex: "DFB5D6")], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: 7) {
                ForEach(0..<3) { index in RoundedRectangle(cornerRadius: 5).fill([Color(hex: "709CDA"), Color(hex: "B58BCC"), Color(hex: "DEB672")][index]).frame(width: 21, height: 25) }
            }.padding(10).background { surface }.clipShape(RoundedRectangle(cornerRadius: 13))
        }.frame(width: 125, height: 65).accessibilityHidden(true)
    }
    @ViewBuilder private var surface: some View {
        switch material {
        case .frosted: RoundedRectangle(cornerRadius: 13).fill(.regularMaterial)
        case .dark: RoundedRectangle(cornerRadius: 13).fill(Color.black.opacity(0.72))
        case .clear: RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.22)).overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.35)))
        case .liquidGlass: Color.clear.dockGlass(cornerRadius: 13)
        }
    }
}
