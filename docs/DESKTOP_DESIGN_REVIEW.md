# 桌面界面与动效审查

本轮将 [Emil Kowalski 的 skills](https://github.com/emilkowalski/skills) 用于原生 SwiftUI / AppKit 桌面界面。14 个技能已安装于开发环境；使用 `emil-design-eng`、`apple-design`、`review-animations` 和 `break-ui` 的适用原则。参考版本为 `e8a175de22ae1e49370fc144c1f3bb9aeedf988d`，未引入 WebView、React 或动画依赖。

## 原则如何用于 macOS

- 布局选择、搜索、键盘命令和频繁滚动立即响应，选中反馈以颜色与边线为主。
- 玻璃用于导航与浮动工具栏；正文和选择卡片使用安静的阅读背景。
- 图标操作至少提供 32 × 32 pt 的目标、明确名称与焦点反馈。
- 长文件名采用中间省略，保留版本及扩展名；完整名称仍通过提示和辅助功能读取。
- 使用系统 ScrollView 与 popover。网页的 CSS / GPU 规则没有逐字转换到原生窗口动画。
- 减少动态效果时取消位移与缩放，减少透明度及增加对比度沿用系统适配。

## 改动审查

| Before | After | Why |
| --- | --- | --- |
| 多选操作和说明固定在同一行；快捷键与颜色选择共享窄行 | [管理页按可用宽度自动改为上下排列](../Sources/OpenDock/Views/ManagerView.swift#L166) | 最小窗口仍能读说明并点到所有操作 |
| 布局与文件名末尾被截断，相近版本难以区分 | [中间省略、完整提示与辅助名称](../Sources/OpenDock/Views/ManagerView.swift#L225) | 保留 v12 / v13 和文件扩展名 |
| plain 选项卡缺少一致的 hover、按下与焦点反馈 | [共用即时颜色与边线样式，不移动卡片内容](../Sources/OpenDock/Views/Theme.swift#L133) | 高频选择反馈清楚且布局稳定 |
| 玻璃按钮按下和松开使用相同补间 | [删除自定义缩放补间；按下/松开即时颜色反馈](../Sources/OpenDock/Views/Theme.swift#L120) | 输入立即得到回应 |
| 组件卡片描述限两行、固定高度，图标再叠玻璃 | [描述完整换行、阅读卡片与统一图标反馈](../Sources/OpenDock/Views/WidgetLibraryView.swift#L119) | 用途可以完整读到，减少材质层叠 |
| 共享弹窗标题只能一行，尾部关闭按钮挤压动作 | [关闭移至前侧，标题/副标题允许换行，独立动作区](../Sources/OpenDock/Widgets/LocalWidgetEnhancements.swift#L47) | 符合桌面窗口习惯，长文本不遮挡操作 |
| 引导选项详情受固定限高影响；步骤按键也播放补间 | [更清晰的选项与弹性内容，步骤立即切换](../Sources/OpenDock/Views/WalkthroughView.swift#L31) | 阅读与键盘路径更加直接 |
| 触控板惯性可能继续触发布局切换 | [同次手势只切换一次、忽略惯性阶段](../Sources/OpenDock/Services/DockPanelController.swift#L12) | 一次滑动对应一次切换 |
| 缩放取消后可能留下起始值，新项目延迟滚动可能抢操作 | [取消时重置](../Sources/OpenDock/Views/CustomDockView.swift#L181)；[用户拖拽/缩放时不抢滚动](../Sources/OpenDock/Views/CustomDockView.swift#L146) | 后续手势从当前状态开始 |

## 边界数据

验收数据仅位于 `/tmp` 的隔离布局：中文长工作区名称、只有 v12 / v13 不同的两个 PDF 名称、长相机文件名、带变音符号的 Markdown 名称、空布局和一个项目的布局。没有在公开仓库加入个人数据，也没有修改产品默认文案来模拟这些值。

具体构建、测试、界面验收及未覆盖环境见 [验证记录](VERIFICATION.md)。动效审查结论将在该记录中按本版验证范围列明。

开发验收可在独立 bundle 身份与临时归档下使用 `--ui-test --ui-test-compact`，以 940 × 680 pt 启动管理窗；同时必须设置 `OPENDOCK_TEST_ARCHIVE`，避免读取个人布局。正式启动尺寸仍为 1100 × 760 pt。
