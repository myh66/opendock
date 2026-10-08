# 更新记录

## 0.2.0 Beta 1 — 2026-10-08

- 按 Dockset 0.2.6 的公开功能说明扩展到 25 种组件，包括闹钟、网络、股票/自选行情、Stripe、Paddle、Shopify、AI Limits 与 AI Activity。
- 接入七种 AI 额度来源；活动来源限 Codex、Claude、Cursor、Grok。增加共享连接、额度显隐与样式、日期范围、Claude Desktop 备用读取和 Copilot CLI 只读 SDK 协议。
- 增加 Focus Filter/App Intents、可录制快捷键、轨迹板切换、多选编辑、应用组、窗口预览缓存、角标、窗口避让、桌面模式与 Liquid Glass。
- 完善原生 Dock 排队切换、备份校验与失败回滚，增加系统通知、天气预报/定位、播放器控制和经过校验的 GitHub 更新。
- 股票增加拖动区间涨跌比较；外设电池只读系统已发布的电量，已充满标记优先于冲突的充电标记。
- 91 项单元测试通过；桥接修正阶段的 84 项套件连续复测两次；实际界面与股票联网完成指定范围验证。实号、系统权限、多屏/多 Space、原生 Dock 写入回滚与覆盖安装仍待实际验证，详见 [验证记录](docs/VERIFICATION.md) 与 [逐项功能矩阵](docs/PARITY.md)。

本版为 arm64、ad hoc 签名、未公证的开发 Beta；不表示 Dockset 0.2.6 在所有环境已完整实测兼容。

## 0.1.0 — 初始开发 Beta

- 独立实现 OpenDock 的布局模型、编辑器、自定义原生 Dock 与系统交互服务。
- 提供本地配置、导入导出、菜单栏切换和组件库。
- 提供原生 Dock 备份、应用与恢复流程。
- 增加 SwiftPM 构建、测试、原创应用图标、`.app` / DMG 打包脚本与 macOS CI。
- 采用 MIT License，并提供中英文 README、隐私说明和功能对照。

此记录描述初始版本范围。具体组件覆盖、已完成验证与待实现能力见 [功能对照](docs/FEATURES.md) 和 [验证清单](docs/VERIFICATION.md)。不包含 Dockset 的专有付费授权机制。
