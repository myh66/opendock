import SwiftUI

struct WalkthroughView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var mode: DockMode = .both
    @State private var widgets: Set<WidgetKind> = [.clock, .note]
    @State private var createLayout = true
    @State private var layoutName = "我的 Dock"
    @State private var finishing = false
    private let suggestions: [WidgetKind] = [.clock, .note, .focus, .hydration, .battery, .system]
    private let titles = ["桌面，跟随你的工作。", "把常用工具放在手边。", "准备好你的第一个布局。"]
    private let details = ["选择 Dock 的使用方式。完成引导后生效，之后可在设置中调整。", "挑选几个无需授权的组件，看看它们组合在一起的样子。", "可以新建一个布局，也可以保留现有布局直接开始使用。"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                BrandMark(size: 44).accessibilityHidden(true)
                Spacer()
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule().fill(index == step ? DockTheme.accent : DockTheme.secondary.opacity(0.2))
                                .frame(width: index == step ? 22 : 7, height: 7)
                        }
                    }.accessibilityHidden(true)
                    Text("\(step + 1) / 3").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }.accessibilityElement(children: .ignore).accessibilityLabel("第 \(step + 1) 步，共三步")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(titles[step]).font(.system(size: 26, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(details[step]).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Group {
                        if step == 0 { modeOptions }
                        else if step == 1 { widgetOptions }
                        else { completionOptions }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }.padding(.bottom, 6)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Button("稍后再看") { finish(apply: false) }
                    .buttonStyle(DockGlassButtonStyle()).keyboardShortcut(.cancelAction)
                    .help("关闭引导，保留当前布局与设置。")
                Spacer(minLength: 0)
                DockGlassGroup {
                    HStack(spacing: 10) {
                        if step > 0 { Button("上一步") { changeStep(-1) }.buttonStyle(DockGlassButtonStyle()) }
                        Button(step == 2 ? "开始使用" : "下一步") {
                            if step == 2 { finish(apply: true) } else { changeStep(1) }
                        }.buttonStyle(DockGlassButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }.padding(24)
            .frame(minWidth: 440, idealWidth: 580, maxWidth: 620, minHeight: 440, idealHeight: 560, maxHeight: 650)
            .background(DockAppBackdrop()).tint(DockTheme.accent).disabled(finishing)
            .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
            .onAppear { finishing = false; mode = store.settings.mode; createLayout = !store.settings.hasCompletedTour }
    }

    private var modeOptions: some View {
        VStack(spacing: 10) {
            ForEach(DockMode.allCases) { option in
                Button { mode = option } label: {
                    HStack(spacing: 14) {
                        Image(systemName: option == .nativeOnly ? "macwindow" : option == .both ? "rectangle.3.group" : "dock.rectangle")
                            .font(.system(size: 22)).foregroundStyle(DockTheme.accent).frame(width: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(option.title).font(.system(size: 13, weight: .semibold))
                            Text(modeDetail(option)).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: mode == option ? "checkmark.circle.fill" : "circle").foregroundStyle(mode == option ? DockTheme.accent : DockTheme.secondary.opacity(0.5))
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).dockCard(cornerRadius: 18)
                }.buttonStyle(DockSelectableCardStyle(selected: mode == option, cornerRadius: 18))
                    .accessibilityLabel(option.title).accessibilityValue(mode == option ? "已选择" : "未选择")
                    .accessibilityHint(modeDetail(option)).accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
    }
    private func modeDetail(_ option: DockMode) -> String {
        switch option {
        case .nativeOnly: return "保存和切换系统布局，使用原有 macOS Dock。"
        case .both: return "保留系统 Dock，让自定义 Dock 放置更多工具。"
        case .replacement: return "以自定义 Dock 为主，系统 Dock 隐藏至屏幕边缘。"
        }
    }
    private var widgetOptions: some View {
        VStack(spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(suggestions) { kind in
                    Button { if widgets.contains(kind) { widgets.remove(kind) } else { widgets.insert(kind) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: kind.symbol).foregroundStyle(DockTheme.accent)
                            Text(kind.title).font(.system(size: 13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: widgets.contains(kind) ? "checkmark.circle.fill" : "circle").foregroundStyle(widgets.contains(kind) ? DockTheme.accent : DockTheme.secondary.opacity(0.4))
                        }.padding(13).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).dockCard(cornerRadius: 14)
                    }.buttonStyle(DockSelectableCardStyle(selected: widgets.contains(kind), cornerRadius: 14))
                        .accessibilityLabel(kind.title).accessibilityValue(widgets.contains(kind) ? "已选择" : "未选择")
                        .accessibilityHint("选择或移除此组件。").accessibilityAddTraits(widgets.contains(kind) ? .isSelected : [])
                }
            }
            VStack(spacing: 14) {
                Text("布局预览").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                if widgets.isEmpty {
                    Text("可先创建空白布局，再添加组件。").font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(16).frame(maxWidth: .infinity).dockCard(cornerRadius: 18)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 65, maximum: 85), spacing: 10)], spacing: 14) {
                        ForEach(suggestions.filter { widgets.contains($0) }) { kind in
                            VStack(spacing: 7) {
                                Image(systemName: kind.symbol).font(.system(size: 23)).foregroundStyle(DockTheme.accent)
                                Text(kind.title).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, minHeight: 65)
                        }
                    }.padding(14).dockCard(cornerRadius: 18)
                        .accessibilityElement(children: .ignore).accessibilityLabel("布局预览，\(widgets.count) 个组件")
                }
                Text("新布局可沿用当前固定应用，组件内容可在添加后设置。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).padding(.vertical, 18)
        }
    }
    private var completionOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield").font(.system(size: 27)).foregroundStyle(DockTheme.accent).accessibilityHidden(true)
                Text("布局保存在本机，按需连接。\n日历、音乐及账户都在你主动连接后使用。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(mode.title).font(.system(size: 13, weight: .semibold))
                if mode != .nativeOnly {
                    Toggle("创建并使用新布局", isOn: $createLayout)
                    if createLayout {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("布局名称").font(.system(size: 12, weight: .medium))
                            TextField("我的 Dock", text: $layoutName).textFieldStyle(.roundedBorder).accessibilityLabel("新布局名称")
                            Text(layoutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "留空会使用「我的 Dock」。" : "\(widgets.count) 个组件 · 保留已有布局")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else { Text("现有系统 Dock 内容会保留；在管理页选择已保存的布局即可切换。").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(18).dockCard(cornerRadius: 18)
            Label("可在设置中重新查看引导、恢复系统 Dock 或导出布局。", systemImage: "slider.horizontal.3")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func changeStep(_ delta: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { step = min(max(step + delta, 0), titles.count - 1) }
    }
    private func finish(apply: Bool) {
        guard !finishing else { return }
        finishing = true
        var updated = store.archive
        var createdID: UUID?
        if apply {
            updated.settings.mode = mode
            if mode != .nativeOnly { updated.settings.showCustomDock = true }
            if createLayout && mode != .nativeOnly {
                let trimmed = layoutName.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = trimmed.isEmpty ? "我的 Dock" : trimmed
                let apps = (store.activeCustom?.items ?? []).filter { $0.kind == .app }.map(AppStore.independentCopy)
                let additions = suggestions.filter { widgets.contains($0) }.map { DockItem(kind: .widget, title: $0.title, widget: $0) }
                let profile = DockProfile(name: name, items: apps + (apps.isEmpty || additions.isEmpty ? [] : [DockItem(kind: .spacer)]) + additions)
                updated.profiles.append(profile); updated.activeCustomID = profile.id
                createdID = profile.id
            }
        }
        updated.settings.hasCompletedTour = true
        store.archive = updated
        if let createdID { store.selectedID = createdID }
        store.tourPresented = false
    }
}
