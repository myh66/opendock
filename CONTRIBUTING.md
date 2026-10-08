# 贡献指南

欢迎改进 OpenDock。请先阅读 [功能对照](docs/FEATURES.md) 和 [安全说明](SECURITY.md)。

## 本地开发

```sh
swift build
swift test
./scripts/build-app.sh
open build/OpenDock.app
```

SwiftPM 源文件位于 `Sources/OpenDock`，单元测试位于 `Tests/OpenDockTests`。打包工具位于 `scripts`，用户文档位于 `docs`。使用 SwiftUI 组织编辑界面，用 AppKit 实现原生面板和系统交互。保持无外部运行时依赖。

## 提交要求

- 聚焦一个问题，描述触发条件、修改后的行为和实际验证范围。
- 新增系统调用必须说明使用的权限、拒绝权限后的行为与数据保存位置。
- 处理配置文件与原生 Dock 的改动应有验证、修改前备份和失败恢复路径。
- 重要业务逻辑应添加有意义的单元测试；真实 UI、权限与多显示器行为需要手工验证，不能用编译成功代替。
- 对照文档必须准确区分已实现、已测试和待实现功能。
- 只提交自己的代码与允许再分发的资源；不要加入 Dockset 的代码、图标、截图或付费服务凭据。

欢迎使用中文或英文提交 issue/PR。分享日志或 JSON 前移除用户名、私有文件路径、日历内容、提醒事项、便签与账户信息。未经过用户主动操作，不应应用或清空 Apple Dock、删除文件或完成提醒事项。

代码与原创资源通过提交贡献按仓库 MIT License 授权。
