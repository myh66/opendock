import SwiftUI

struct WalkthroughView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var mode: DockMode = .both
    @State private var widgets: Set<WidgetKind> = [.clock, .note]
    @State private var createLayout = true
    @State private var layoutName = "我的 Dock"
    private let suggestions: [WidgetKind] = [.clock, .note, .focus, .hydration, .battery, .system]
    private let titles = ["桌面，跟随你的工作。", "把常用工具放在手边。", "准备好你的第一个布局。"]
    private let details = ["选择 Dock 的使用方式。完成引导后生效，之后可在设置中调整。", "挑选几个无需授权的组件，看看它们组合在一起的样子。", "可以新建一个布局，也可以保留现有布局直接开始使用。"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                BrandMark(size: 44)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in Capsule().fill(index == step ? DockTheme.accent : DockTheme.secondary.opacity(0.2)).frame(width: index == step ? 22 : 7, height: 7) }
                }.accessibilityLabel("第 \(step + 1) 步，共三步")
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(titles[step]).font(.system(size: 27, weight: .semibold))
                Text(details[step]).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            }
            Group {
                if step == 0 { modeOptions }
                else if step == 1 { widgetOptions }
                else { completionOptions }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("稍后再看") { finish(apply: false) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                DockGlassGroup {
                    HStack(spacing: 10) {
                        if step > 0 { Button("上一步") { changeStep(-1) }.buttonStyle(DockGlassButtonStyle()) }
                        Button(step == 2 ? "开始使用" : "下一步") {
                            if step == 2 { finish(apply: true) } else { changeStep(1) }
                        }.buttonStyle(DockGlassButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }.padding(30).frame(width: 580, height: 560).background(DockAppBackdrop()).tint(DockTheme.accent)
            .onAppear { mode = store.settings.mode; createLayout = !store.settings.hasCompletedTour }
    }

    private var modeOptions: some View {
        VStack(spacing: 10) {
            ForEach(DockMode.allCases) { option in
                Button { mode = option } label: {
                    HStack(spacing: 14) {
                        Image(systemName: option == .nativeOnly ? "macwindow" : option == .both ? "rectangle.3.group" : "dock.rectangle")
                            .font(.system(size: 22)).foregroundStyle(DockTheme.accent).frame(width: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(option.title).font(.system(size: 13, weight: .medium))
                            Text(modeDetail(option)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: mode == option ? "checkmark.circle.fill" : "circle").foregroundStyle(mode == option ? DockTheme.accent : DockTheme.secondary.opacity(0.5))
                    }.padding(16).dockCard(cornerRadius: 18)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(mode == option ? DockTheme.accent.opacity(0.6) : .clear))
                }.buttonStyle(.plain).accessibilityAddTraits(mode == option ? .isSelected : [])
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(suggestions) { kind in
                    Button { if widgets.contains(kind) { widgets.remove(kind) } else { widgets.insert(kind) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: kind.symbol).foregroundStyle(DockTheme.accent)
                            Text(kind.title).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                            Image(systemName: widgets.contains(kind) ? "checkmark.circle.fill" : "circle").foregroundStyle(widgets.contains(kind) ? DockTheme.accent : DockTheme.secondary.opacity(0.4))
                        }.padding(13).dockCard(cornerRadius: 14)
                    }.buttonStyle(.plain).accessibilityAddTraits(widgets.contains(kind) ? .isSelected : [])
                }
            }
            VStack(spacing: 14) {
                Text("布局预览").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 15) {
                    if widgets.isEmpty { Text("可先创建空白布局，再添加组件。").font(.caption).foregroundStyle(.secondary).padding(10) }
                    ForEach(suggestions.filter { widgets.contains($0) }) { kind in
                        VStack(spacing: 6) { Image(systemName: kind.symbol).font(.system(size: 23)).foregroundStyle(DockTheme.accent); Text(kind.title).font(.system(size: 10)).foregroundStyle(.secondary) }.frame(width: 58, height: 57)
                    }
                }.padding(12).dockGlass(cornerRadius: 23)
                Text("应用会沿用当前自定义布局，组件内容可在添加后设置。").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 18)
        }
    }
    private var completionOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) { Image(systemName: "checkmark.shield").font(.system(size: 27)).foregroundStyle(DockTheme.accent); Text("按需连接，数据留在本机。\n日历、音乐及账户都在你主动连接后使用。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4) }
            VStack(alignment: .leading, spacing: 14) {
                Text(mode.title).font(.system(size: 13, weight: .semibold))
                if mode != .nativeOnly {
                    Toggle("创建并使用新布局", isOn: $createLayout)
                    if createLayout {
                        TextField("布局名称", text: $layoutName).textFieldStyle(.roundedBorder)
                        Text("\(widgets.count) 个组件 · 保留已有布局").font(.caption).foregroundStyle(.secondary)
                    }
                } else { Text("现有系统 Dock 内容会保留；在管理页选择已保存的布局即可切换。").font(.caption).foregroundStyle(.secondary) }
            }.padding(18).dockCard(cornerRadius: 18)
            Label("可在设置中重新查看引导、恢复系统 Dock 或导出布局。", systemImage: "slider.horizontal.3").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func changeStep(_ delta: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { step += delta }
    }
    private func finish(apply: Bool) {
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
