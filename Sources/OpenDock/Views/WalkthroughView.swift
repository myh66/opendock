import SwiftUI
struct WalkthroughView:View {
    @EnvironmentObject var store:AppStore
    @State private var step = 0
    private let titles = ["桌面，跟随你的工作。","把常用工具放在手边。","按需连接，数据留在本机。"]
    private let details = ["保存独立的 macOS 布局与自定义 Dock。可通过菜单栏、全局快捷键和专注模式切换。","拖动添加应用、文件、文件夹与链接；按 ⌘ / ⇧ 选中多个项目。组件右键可复制设置，弹窗里调整内容。","日历、音乐和窗口权限由你主动开启。AI 与商业账户先连接再显示真实数据，密钥保存在钥匙串。"]
    var body:some View {
        VStack(alignment:.leading,spacing:24) {
            HStack { BrandMark(size:48); Spacer(); Text("\(step + 1) / 3").font(.caption).foregroundStyle(.secondary) }
            Text(titles[step]).font(.system(size:27,weight:.semibold))
            Text(details[step]).font(.system(size:13)).foregroundStyle(.secondary).lineSpacing(6).frame(height:95,alignment:.top)
            if step == 0 { Picker("使用方式",selection:Binding(get:{store.settings.mode},set:{store.settings.mode = $0})) { ForEach(DockMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.radioGroup) }
            else if step == 1 { Label("底部 Dock 上下滑动切换 · 侧边 Dock 左右滑动切换",systemImage:"hand.draw").font(.caption) }
            else { Label("可在设置中随时恢复系统 Dock、导出布局和重新查看引导。",systemImage:"checkmark.shield").font(.caption) }
            Spacer()
            HStack { Button("稍后再看") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary); Spacer(); if step > 0 { Button("上一步") { step -= 1 } }; Button(step == 2 ? "开始使用":"下一步") { if step == 2 { finish() } else { step += 1 } }.buttonStyle(.borderedProminent) }
        }.padding(32).frame(width:540,height:440).tint(DockTheme.accent)
    }
    private func finish() { store.settings.hasCompletedTour = true; store.tourPresented = false }
}
