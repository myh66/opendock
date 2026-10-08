# 功能对照

OpenDock 0.2.0 Beta 根据截至 2026-10-08 的 [Dockset 官网](https://dockset.app)、[0.2.6 更新记录](https://dockset.app/changelog)和[手册](https://dockset.app/manual)实现公开功能。代码独立开发，使用原创图标与 MIT 许可。

| 范围 | 本版实现 |
| --- | --- |
| 三种使用方式 | 原生 Dock、自定义 Dock、两者并用；替代模式备份并恢复自己修改的原生隐藏设置 |
| 布局与编辑 | 保存、切换、复制、多选、批量操作、成组拖动、应用/文件/目录/链接/间隔/应用组；图标颜色和字母；备份合并 |
| 切换 | 菜单栏、每个布局可录制的全局快捷键、轨迹板、⌘滚动、App Intents 快捷指令和 Focus Filter |
| 自定义 Dock | 三边、显示器、尺寸、拖动调整、自动隐藏/边缘停留、滚动溢出、运行中应用固定/取消固定、桌面模式；macOS 26+ Liquid Glass 与旧版本材质 |
| 窗口 | 单窗最小化、窗口菜单、最小化预览缓存、恢复、应用 badge、AX 窗口避让 |
| 时间与效率 | 时钟、世界时钟、秒表、倒计时、专注计时、闹钟、时间进度、便签、饮水、日历、提醒事项 |
| 系统与生活 | CPU/内存/存储、网络、电池、天气预报与定位、Music/Spotify、Shortcuts、AirDrop |
| 商业与行情 | 股票、自选行情、Stripe、Paddle、Shopify；真实只读数据、共享多账号、来源和更新时间 |
| AI | Limits 与 Activity；Codex、Claude、Grok、Cursor、Gemini CLI、Copilot、Antigravity；共享连接、逐额度显隐、顺序、显示样式和日期范围 |
| 发布与维护 | GitHub 更新检查、校验下载与显式安装，首次引导、设置/关于页面记忆、登录启动 |

组件总计 **25 种**（AI Limits/Activity 分开计数）。具体数据源、权限、逐项状态和尚未确认的差异见 [完整矩阵](PARITY.md)、[本地组件](LOCAL_WIDGETS.md)、[外部连接](INTEGRATIONS.md)与[验证证据](VERIFICATION.md)。

Beta 的边界：外部账号与权限操作尚未逐一实号验证；任意 Space 跳转使用公共 AX 尽力恢复；没有 Dockset 商业许可证兼容；当前分发是 arm64、ad hoc 签名，未公证。源代码覆盖不等于所有 macOS/设备/账号流程完成实测。
