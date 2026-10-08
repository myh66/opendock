# 验证证据

2026-10-08，OpenDock **0.2.0 Beta 1**。代码覆盖、自动测试、实际界面与外部账号验证分别记录。

## 已完成

| 检查 | 结果与范围 |
| --- | --- |
| 完整单元测试 | **84 项通过，0 失败**。归档迁移、稳定排序、通知独立身份、原生序列化/FIFO、模式备份校验、窗口缓存、CPU/网络 delta、存储、商业口径、AI 数据与子进程协议。 |
| 子进程专项复测 | **9 项通过**。分段 stdin/JSONL、只读握手、重复初始化、输入上限、取消、SIGTERM 忽略后的 SIGKILL。仅使用临时合成脚本。修复执行计时在 macOS 启动完成前提前耗尽的问题。 |
| Claude Desktop 合成测试 | 5 项包含在完整测试：独立 PBKDF2/AES 向量、Chromium v23/v24 域绑定、过期/冲突会话、SQLite 字段过滤、数值额度。未访问个人 Cookies 或钥匙串。 |
| 调试和 Release 构建 | Swift 6.4，arm64，macOS 13 编译目标通过。 |
| App Intents 打包 | `appintentsmetadataprocessor` 成功生成 `Metadata.appintents`；提取包含布局 Entity/Query、Switch Intent、Focus Filter 与 App Shortcuts。尚未配置用户的真实 Focus 自动化。 |
| 应用启动 | 最终 `.app` 在隔离布局下启动；25 种组件目录，两个测试布局。`--smoke-test` 正常退出。 |
| 实际界面 | 管理页、关于版本号、设置和 Liquid Glass 选项；自定义布局应用、时钟弹窗/Escape；AI 圆环和逐额度设置；⌘W 关闭 AI 弹窗且管理窗保留；空标题组件显示正确名称。 |
| 股票真实联网 | Yahoo 公开行情返回并显示股票名称、币种、一个月价格历史及成交量图；该端点无稳定 API 保证。 |
| AI 界面数据 | 使用明确标注的合成数值缓存验收显示；未连接个人供应商账户，不代表真实额度查询已验证。 |
| 原生 Dock 保留 | 测试前后 `persistent-apps` 内容与 autohide/延迟/动画设置一致，固定项目 **39 个**。测试未应用或重启用户 Dock。 |
| 签名和封装 | Info.plist 与 ad hoc `codesign --verify --strict` 通过；DMG 创建及 `hdiutil verify` 通过；ZIP 和 DMG 附 SHA-256。 |

隔离界面测试通过 `--ui-test` 和 `OPENDOCK_TEST_ARCHIVE` 指定临时布局及集成缓存；启动/退出跳过原生替代模式恢复和 AX 窗口尺寸调整。合成数据、脚本、测试日志没有纳入发布包。

## 尚未完成的实际验证

- 原生布局写入、快速连续切换、失败回滚、替代模式退出恢复；实现有序列化/队列/快照测试，但没有修改本机 Dock 验收。
- Focus Filter 和 Shortcuts 的系统注册发现与真实执行；元数据存在不等于已配置自动化。
- 多屏、全屏、多个 Space、动态 WallpaperAgent、Mission Control 精确优先级，以及窗口避让/预览/角标的实机组合。
- 日历、提醒事项、通知、定位、Music/Spotify、登录启动的允许/拒绝/升级授权流程；AirDrop 的接收设备传输。
- Stripe、Paddle、Shopify 与七种 AI 来源的实号端到端验证。Gemini 加密凭据、旧 Grok 日志、复杂 Stripe MRR 和非稳定客户端接口限制见 [连接指南](INTEGRATIONS.md)。
- 覆盖安装更新、Intel/macOS 13/14 实机、Universal Binary、Developer ID、公证与 App Store 分发。

此包为 **arm64、ad hoc 签名、未公证的开发 Beta**。不能宣称 Dockset 0.2.6 全部细节已在所有环境完整实测。逐项覆盖见 [功能矩阵](PARITY.md)。

## 持续集成

公开仓库工作流执行构建、测试、带 App Intents 元数据的应用封装与 ZIP 保存。历史初版的 [CI](https://github.com/myh66/opendock/actions/runs/37712447779) 已通过；本版以对应提交的 [Actions](https://github.com/myh66/opendock/actions) 记录为准。CI 使用 macOS 15；运行器架构与本机包分别记录。
