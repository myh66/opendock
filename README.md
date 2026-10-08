# OpenDock

一个使用 SwiftUI 与 AppKit 编写的 macOS Dock 管理器：保存与切换布局，在独立 Dock 中放置应用、文件和组件。macOS 13 Ventura 及以上，无第三方 Swift 包依赖。

[English](README.en.md) · [功能对照](docs/PARITY.md) · [使用说明](docs/USAGE.md) · [贡献指南](CONTRIBUTING.md)

OpenDock 是基于 Dockset 官网公开功能介绍独立实现的开源项目，采用原创名称、图标和代码，与 Dockset 及其开发者没有关联。此仓库不包含 Dockset 源码、安装包、授权机制或商标素材。参考：[官网](https://dockset.app)、[更新记录](https://dockset.app/changelog)、[手册](https://dockset.app/manual)。

## 当前范围

- 自定义布局与 macOS 原生 Dock 布局，编辑应用、文件、文件夹、链接、间隔和应用组。
- 独立原生 Dock 面板，左侧／底部／右侧、尺寸、材质、自动隐藏、运行中应用与组件。
- 菜单栏切换、可录制的布局快捷键、轨迹板切换、Focus Filter 与 App Intents；多选拖动、JSON 备份合并和原生 Dock 回滚。
- Liquid Glass、窗口预览缓存、角标、窗口避让、桌面模式与经过校验的 GitHub 更新。
- 25 种组件入口：时钟、世界时钟、日历、提醒事项、专注计时、便签、电池、系统状态、天气、秒表、倒计时、饮水记录、时间进度、快捷指令、正在播放、AirDrop、闹钟、网络、股票、自选行情、Stripe、Paddle、Shopify、AI 额度与 AI 活动。外部服务需连接可读取的数据来源。
- [本地组件与系统连接](docs/LOCAL_WIDGETS.md)：真实通知排程、可选饮水容量与按日历史、日历／提醒列表、天气预报与定位、播放器封面与进度、网络速率和显式存储扫描。

这是开发中的 Beta，功能覆盖与验证状态详见 [功能对照](docs/PARITY.md)。外部账号、系统权限与跨设备操作需要实际连接后验证；源码与构建通过不代表所有服务、所有 macOS 版本的流程已完成实测。

## 构建与运行

基础源码构建需要 macOS 与 Swift 5.9 以上。完整 `.app` 封装及 App Intents 元数据需要 Xcode 16 以上，并通过 `xcode-select` 选择该 Xcode 工具链。

```sh
swift build
swift test
./scripts/build-app.sh
open build/OpenDock.app
```

日历、提醒事项、音乐自动化、URL Scheme 与登录启动应从 `.app` 测试；`swift run OpenDock` 可用于基础界面开发，但终端进程的权限身份不等同于应用包。

构建脚本输出 `build/OpenDock.app`，生成原创 `.icns` 图标并使用本机 ad hoc 签名。本次本机验证的 Beta 为 Apple Silicon（arm64）；脚本按当前工具链架构构建，CI 产物取决于其 runner 架构，没有生成 Universal Binary。可将应用复制到 `/Applications`，在该位置重新打开后使用。生成便于分发的 DMG：

```sh
./scripts/package-dmg.sh
```

此 Beta 未经 Developer ID 公证，也没有 App Store 分发认证；其他 Mac 可能需要在系统设置中批准打开。ad hoc 签名不保证升级后的权限身份稳定。开发者可显式指定自己的签名身份，公证仍需另外完成：

```sh
OPENDOCK_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-app.sh
```

CI 在 `macos-15` 上构建、运行单元测试并打包应用，产物保留在 GitHub Actions 中。CI 构建通过不代表真机权限、全部 Dock 行为或公证已经验证。

## 数据与权限

布局、组件设置和本地记录存储在这台 Mac；无 OpenDock 账户、遥测或内置同步服务。导出 JSON 可能包含应用路径、文件路径、便签和组件配置，分享前请检查内容。天气是按需请求的外部服务；音乐控制、日历和提醒事项需要相应系统权限。具体数据流与权限见 [隐私说明](docs/PRIVACY.md)。

首次启动创建 OpenDock 自定义布局，并尝试只读保存现有 macOS Dock 的固定应用布局。要修改 Apple 的 Dock，请先保存现有布局，并主动执行原生布局应用操作；该操作会重启 Dock，过程中可能短暂闪动。请阅读 [原生 Dock 备份与恢复](docs/USAGE.md#原生-dock-备份与恢复)。

## 开源

[MIT License](LICENSE) 适用于本项目代码与原创图标；天气数据与 API 遵循 [Open-Meteo 自身条款](https://open-meteo.com/en/terms)。欢迎以小范围 PR 改进真实功能、权限处理、可访问性与测试。请勿提交私人布局、账户令牌或第三方产品素材。

外部账号和数据源设置见 [连接指南](docs/INTEGRATIONS.md)，本地功能见 [组件指南](docs/LOCAL_WIDGETS.md)。
