# 验证证据

代码覆盖、自动测试、实际界面与外部账号验证分别记录。每版证据单独列出，历史结果不代表当前源码或发布包已完成相同检查。

## 0.3.1 Beta 1 — 2026-10-09

| 检查 | 结果与范围 |
| --- | --- |
| 完整单元测试 | 最终源码本机 **129 项通过，0 失败，8.050 秒**（Swift 6.4）。新增 7 项覆盖单手势只切换一次、惯性不累积、无 phase 设备的空闲边界、阈值前反向、缩放起点重置、侧边轴与范围、非有限输入。 |
| Release 与封装 | 最终 Release 构建通过；应用版本 0.3.1、发布标签 v0.3.1-beta.1，App Intents 元数据和 ad hoc 签名检查通过。 |
| 本轮实际界面 | 1100 × 760 pt 管理窗、浅色组件库和 580 × 560 pt 引导。验收长中文布局名、v12/v13 PDF 名称尾部、选择工具栏、设置选项与完整说明；商业分类搜索“世界时钟”得到空态，保留关键词切换全部后返回唯一结果，按 Return 添加一个项目并关闭选择器。 |
| 引导 | Return 进入第二步，六项组件全部选中后预览没有重叠；Escape 等价“稍后再看”，保留两个已有布局、both 模式及原来的 Dock 显示设置。 |
| 启动／退出 | 最终包以 `--ui-test --ui-test-compact --smoke-test`、空／单项目临时归档启动，报告 2 个布局、29 种组件、3 个可见辅助窗口，退出码 0。该检查确认窗口初始化，不能证明实际窄窗排版。 |
| 技能与源码审查 | 14 个技能安装成功；将设计、动效和边界数据原则用于原生代码。完成源码交叉审查，清除分隔符的无效编辑辅助动作，并为组件添加按钮语义。详见 [桌面审查](DESKTOP_DESIGN_REVIEW.md)。 |

本轮使用临时 JSON 归档，没有写入个人布局或应用原生 Dock 布局，也没有请求新权限、读取真实 IBKR/Ollama 账户。

### 本轮未完成的实际验收

- 新隔离身份 `io.github.myh66.opendock.ui-test.compact` 的 Computer Use 访问被自动审批拒绝；工具仅返回 “Computer Use was not approved to use OpenDock”，没有提供具体原因。未绕过审批。因此 940 × 680 pt 最小窗口、深色及空／单项目的追加截图验收未完成，最后的侧栏边线／模式列宽／辅助按钮语义修正经构建和代码复核，未再次截图。
- 真实触控板与鼠标事件组合、取消拖拽、自动隐藏和原生 Dock 显露组合仍需实机验证；7 项纯状态回归不能代替硬件事件验收。
- VoiceOver 实际导航和系统减少动态效果／减少透明度／增加对比度组合仍未操作验收。权限、账户、多屏、多 Space、覆盖升级与公证的其他待验证范围沿用下方记录。

本版仍为 **arm64、ad hoc 签名、未公证的开发 Beta**。源码、指定范围界面及纯状态动效审查结论：**Approve**；上述环境验收边界保留。

### 本版 CI 与发布产物

源码提交 `62c193d` 的 [完整 CI](https://github.com/myh66/opendock/actions/runs/37912319114) 全部通过：macOS 15 arm64、Apple Swift 6.1.2，129 项测试 0 失败（8.149 秒），调试／Release 构建、App Intents、ad hoc 签名和 ZIP 上传通过。CI 检查旧工具链的材质回退路径。

[0.3.1 Beta 1](https://github.com/myh66/opendock/releases/tag/v0.3.1-beta.1) 标签指向该源码提交。公开下载回验的 DMG／ZIP 与本机 SHA-256 一致，ZIP 解压后的签名、0.3.1 版本和 beta.1 标签核对通过；DMG 本机校验通过。该发布包来自本机 Swift 6.4，未覆盖安装到个人 Applications。

| 产物 | SHA-256 |
| --- | --- |
| OpenDock.dmg | `97a0ded2b3702df55ddfc1fc672a0678b5e538de49c29a96fc532d94c66b55d9` |
| OpenDock-macOS.zip | `7e8c006b4e50b43405ac2d459e3a4eb4ca710db08b94159be782e521b64bbdec` |

## 0.3.0 Beta 1 — 2026-10-09

### 已完成

| 检查 | 结果与范围 |
| --- | --- |
| 完整单元测试 | 本机最终 **122 项通过，0 失败，8.148 秒**（Swift 6.4）。保留 91 项原有测试，新增结构化拖拽 4 项、IBKR 6 项、Ollama 10 项、网易云链接 6 项、系统代理 5 项；覆盖账户 BASE 汇总、地址草稿导出保护、响应数值边界和链接规范化。 |
| Release 构建 | 最终源码的 Release 构建通过，arm64、macOS 13 编译目标；原生 Liquid Glass 在 macOS 27 验收，旧工具链路径由 CI 检查。 |
| App Intents 与签名 | 最终应用包生成布局 Entity/Query、Switch Intent、Focus Filter 与 App Shortcuts 元数据，ad hoc 签名检查通过。尚未配置或执行真实 Focus Filter / Shortcuts 自动化。 |
| 隔离界面 | 隔离布局下验收管理/设置、浅色与深色组件库和引导；修复玻璃背景把文字一起模糊的问题，实际确认标题与选项清晰。目录 **29 种**；按服务搜索、空结果/清除、添加后关闭选择器、Ollama 文本框中 ⌘W 关闭并保留管理窗、IBKR/Shadowrocket Escape 关闭。 |
| 启动／退出 | 最终包使用 `--ui-test --smoke-test` 和临时归档启动，报告 2 个布局、29 种组件，正常退出；没有应用个人原生布局。 |
| Ollama 合成 HTTP | 实际服务读取代码对临时回环 HTTP fixture 的 8 个场景通过：三 GET 完整快照、503、schema 错误、拒绝 302、已声明超限响应、取消、约 5 秒无响应超时、失败后重新读取。24 次 GET 没有认证／Cookie；未访问真实服务，fixture 已停止。未知长度流与持续流资源超时仍待验证。 |
| 新组件的验证范围 | 网易云组件实际识别本机运行状态，使用合成官方链接验收收藏保存，未执行歌曲播放。Shadowrocket 显示真实客户端进程与系统代理只读摘要，未修改网络。Ollama 合成敏感地址显示“仅内存未保存”，布局 JSON 确认不含合成秘密；未进行真实 Ollama/IBKR 读取。边界见 [连接指南](INTEGRATIONS.md)。 |

上述界面检查使用临时布局，未写入个人配置、未请求新权限。关于页重播引导、选择模式后仍保留原设置、跳过后保留两个布局均已实际确认。最终 ZIP / DMG 创建，DMG 校验通过；公开发布下载回验，两份产物与 SHA-256 均匹配，标签指向 `192a18a`；测试前后系统 Dock 的 39 个固定项目与隐藏/延迟/动画设置一致。

### 待完成与尚未实测

- 多选跨布局拖拽、拖出后取消、自定义 Dock 自动隐藏与缩放的完整实机组合；减少透明度、增加对比度及减少动态效果的系统组合验收。
- IBKR 真实 Client Portal Gateway 登录、可信本机 HTTPS 证书、账本／账户切换与持仓分页；Ollama 实际本机模型状态读取；网易云和 Shadowrocket 的客户端启动操作。
- 原生 Dock 布局写入、连续切换、失败回滚、替换模式退出恢复；Focus Filter 与 Shortcuts 的系统注册发现和真实执行。
- 多屏、全屏、多个 Space、窗口避让，以及日历／提醒事项／通知／定位／播放器／登录启动的授权与升级流程；AirDrop 接收设备传输。
- 商业账号、七个 AI 额度来源与四个 AI 活动来源的实号端到端验证；覆盖安装更新、Intel/macOS 13/14 实机、Universal Binary、Developer ID、公证与 App Store 分发。

本版是 **arm64、ad hoc 签名、未公证的开发 Beta**。不能宣称 Dockset 0.2.6 的全部细节已在所有环境完整实测。功能覆盖见 [功能矩阵](PARITY.md)。

### 本版持续集成

源码提交 `192a18a` 的 [完整 CI](https://github.com/myh66/opendock/actions/runs/37907719662) 已通过：macOS 15 arm64、Apple Swift 6.1.2，122 项测试 0 失败（8.286 秒），调试及 Release 构建、App Intents 元数据、ad hoc 签名和 ZIP 产物上传均通过。该工作流检查旧工具链材质回退；公开安装包来自本机 Swift 6.4 构建，原生玻璃在 macOS 27 实测。

## 0.2.0 Beta 1 — 2026-10-08（历史证据）

### 当版已完成

| 检查 | 结果与范围 |
| --- | --- |
| 完整单元测试 | **91 项通过，0 失败**（本机 Swift 6.4，6.626 秒）。桥接修正阶段的 84 项套件连续两次通过（9.60 秒、7.78 秒）；新增股票区间和外设电池共 7 项后完成最终整套复测。归档迁移、稳定排序、通知独立身份、原生序列化/FIFO、模式备份校验、窗口缓存、CPU/网络 delta、存储、商业口径、AI 数据与子进程协议、股票区间涨跌/数值边界、外设满电优先/设备去重。 |
| 子进程专项复测 | **9 项通过**。分段 stdin/JSONL、只读握手、重复初始化、输入上限、取消、SIGTERM 忽略后的 SIGKILL。仅使用临时合成脚本。修复执行计时在 macOS 启动完成前提前耗尽的问题。 |
| CLI 环境隔离 | 合成 fixture 验证剔除 SwiftPM/XCTest 的动态库加载与测试注入变量（`DYLD_`、`__XPC_DYLD_`、`XCTest`、`XCTEST_`、`XCInject`、`__XCODE_BUILT_PRODUCTS_DIR_PATHS`、`LLVM_PROFILE_FILE`），保留普通 CLI 登录、代理、配置和 PATH 环境；未执行个人已登录 CLI。 |
| Claude Desktop 合成测试 | 5 项包含在完整测试：独立 PBKDF2/AES 向量、Chromium v23/v24 域绑定、过期/冲突会话、SQLite 字段过滤、数值额度。未访问个人 Cookies 或钥匙串。 |
| 调试和 Release 构建 | Swift 6.4，arm64，macOS 13 编译目标通过。 |
| App Intents 打包 | `appintentsmetadataprocessor` 成功生成 `Metadata.appintents`；提取包含布局 Entity/Query、Switch Intent、Focus Filter 与 App Shortcuts。尚未配置用户的真实 Focus 自动化。 |
| 应用启动 | 最终 `.app` 在隔离布局下启动；25 种组件目录，两个测试布局。`--smoke-test` 正常退出。 |
| 实际界面 | 管理页、关于版本号、设置和 Liquid Glass 选项；自定义布局应用、时钟弹窗/Escape；AI 圆环和逐额度设置；⌘W 关闭 AI 弹窗且管理窗保留；空标题组件显示正确名称；股票日期选择展开后比较整个范围，实际显示金额、百分比及起止日期/跨度（拖动输入仍仅有源码/计算测试证据）。 |
| 股票真实联网 | Yahoo 公开行情返回并显示股票名称、币种、一个月价格历史及成交量图；该端点无稳定 API 保证。 |
| AI 界面数据 | 使用明确标注的合成数值缓存验收显示；未连接个人供应商账户，不代表真实额度查询已验证。 |
| 外设电池 | 3 项合成 fixture 通过，覆盖容量校验、满电/充电冲突、未知状态与同一设备节点去重。本机只读查询返回 0 个外设电量源，尚无真实配件充电验证。 |
| 原生 Dock 保留 | 测试前后 `persistent-apps` 内容与 autohide/延迟/动画设置一致，固定项目 **39 个**。测试未应用或重启用户 Dock。 |
| 签名和封装 | Info.plist 与 ad hoc `codesign --verify --strict` 通过；DMG 创建及 `hdiutil verify` 通过；ZIP 和 DMG 附 SHA-256。 |

隔离界面测试通过 `--ui-test` 和 `OPENDOCK_TEST_ARCHIVE` 指定临时布局及集成缓存；启动/退出跳过原生替代模式恢复和 AX 窗口尺寸调整。合成数据、脚本、测试日志没有纳入发布包。

### 当版尚未完成的实际验证

- 原生布局写入、快速连续切换、失败回滚、替代模式退出恢复；实现有序列化/队列/快照测试，但没有修改本机 Dock 验收。
- Focus Filter 和 Shortcuts 的系统注册发现与真实执行；元数据存在不等于已配置自动化。
- 多屏、全屏、多个 Space、动态 WallpaperAgent、Mission Control 精确优先级，以及窗口避让/预览/角标的实机组合。
- 日历、提醒事项、通知、定位、Music/Spotify、登录启动的允许/拒绝/升级授权流程；AirDrop 的接收设备传输。
- Stripe、Paddle、Shopify 与七种 AI 来源的实号端到端验证。Gemini 加密凭据、旧 Grok 日志、复杂 Stripe MRR 和非稳定客户端接口限制见 [连接指南](INTEGRATIONS.md)。
- 覆盖安装更新、Intel/macOS 13/14 实机、Universal Binary、Developer ID、公证与 App Store 分发。

该版发布包为 **arm64、ad hoc 签名、未公证的开发 Beta**。这些检查不代表 Dockset 0.2.6 全部细节已在所有环境完整实测。

### 当版持续集成

0.2.0 对应的公开仓库工作流执行构建、91 项测试、带 App Intents 元数据的应用封装与 ZIP 保存。提交 `1add8e8` 的 [完整 CI](https://github.com/myh66/opendock/actions/runs/37773079887) 已通过：macOS 15 arm64、Apple Swift 6.1.2，91 项测试 0 失败（7.586 秒），元数据/签名验证与 ZIP 产物上传成功。当版本机使用 Swift 6.4。打包脚本按编译器能力选择常量提取参数，并验证切换 action、Focus Filter、布局 entity 与 App Shortcut；该结果不能替代 0.3.0 发布检查。
