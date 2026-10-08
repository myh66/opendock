# OpenDock

一个使用 SwiftUI 与 AppKit 编写的 macOS Dock 管理器：保存与切换布局，在独立 Dock 中放置应用、文件和组件。macOS 13 Ventura 及以上，无第三方 Swift 包依赖。

[English](README.en.md) · [功能对照](docs/FEATURES.md) · [使用说明](docs/USAGE.md) · [贡献指南](CONTRIBUTING.md)

OpenDock 是基于 Dockset 官网公开功能介绍独立实现的开源项目，采用原创名称、图标和代码，与 Dockset 及其开发者没有关联。此仓库不包含 Dockset 源码、安装包、授权机制或商标素材。参考：[官网](https://dockset.app)、[更新记录](https://dockset.app/changelog)、[手册](https://dockset.app/manual)。

## 当前范围

- 自定义布局与 macOS 原生 Dock 布局，编辑应用、文件、文件夹、链接、间隔和应用组。
- 独立原生 Dock 面板，左侧／底部／右侧、尺寸、材质、自动隐藏、运行中应用与组件。
- 菜单栏切换、全局快捷键、JSON 导入导出，以及原生 Dock 修改前的备份和恢复。
- 16 种组件：时钟、世界时钟、日历、提醒事项、专注计时、便签、电池、系统状态、天气、秒表、倒计时、饮水记录、时间进度、快捷指令、正在播放、AirDrop。

这是首个开发版本，功能覆盖与验证状态详见 [功能对照](docs/FEATURES.md)。商业服务、AI 用量接口、缓存窗口缩略图及原生 Focus Filter 尚未提供，不能视为 Dockset 0.2.6 的完整替代。

## 构建与运行

需要 macOS 和 Xcode Command Line Tools，Swift 5.9 或以上。若尚未安装工具，可运行 `xcode-select --install`。

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
