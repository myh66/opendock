# Dockset 0.2.6 功能对照与验证边界

对照日期：2026-10-09。范围来自 [Dockset 官网](https://dockset.app/)、[截至 0.2.6 的 changelog](https://dockset.app/changelog) 和公开手册。OpenDock 是独立的 MIT 开源实现，使用自己的名称、图标和 SwiftUI 界面；此表不表示获得 Dockset 官方授权，也不表示逐像素一致。

本表是当前扩展版的逐项对照基准；概览见 `FEATURES.md`，验证按 `VERIFICATION.md` 的版本/阶段判断。早期 0.1.0 Beta 结果不能替代本次扩展版验证。

| 状态 | 含义 |
| --- | --- |
| `implemented` | 已有可调用实现与对应界面；权限、设备或实号行为仍须在目标环境验证。 |
| `source tested` | 注明范围的纯函数/临时文件 fixture 测试通过；不代表整个系统调用链已经执行。 |
| `live verified` | 实际执行了该项操作并记录环境和结果；没有最终证据的项目不使用此标签。 |
| `account required` | 还需要用户连接相应服务、工具或系统账户；本表尚无实号端到端验证。 |
| `unavailable` | 指定子功能未实现、未接入界面，或平台/服务不提供可靠数据。 |

当前 native/window/system 服务的隔离 SwiftPM 编译通过（macOS 13 部署目标、Swift 5 语言模式），26 项测试通过：NativeDock 6、Store 9、WindowServices 5、SystemMetrics 3、StorageScanner 3。测试只使用临时文件与数值 fixture：没有应用/恢复用户原生 Dock、重启 Dock、请求系统权限、捕获桌面或扫描用户磁盘。完整产品构建、最终 UI 和集成测试由 [验证记录](VERIFICATION.md) 单独记录，不能从本段推断已通过。

追加的 Claude Desktop 隔离编译与 5 项合成 fixture 也通过，覆盖独立加密向量、域/版本/密钥拒绝、会话安全、临时 SQLite 与数值解析，没有访问个人 Keychain/Cookies 或网络账号。产品 Release 构建已通过；最终 UI/整套测试/包签名证据仍以验证记录为准。

## 布局、编辑和应用

范围参考 [产品说明](https://dockset.app/) 与 [自定义 Dock 手册](https://dockset.app/manual/use-custom-docks)。

| 功能 | 状态 | 实现与边界 |
| --- | --- | --- |
| 独立原生/自定义布局 | `source tested` | 分开保存 activeNativeID/activeCustomID；Store fixture 覆盖复制身份、删除活动布局。 |
| 菜单栏选择、活动名称 | `implemented` | 可选择两类布局、开启活动名称；原生选择会写系统偏好，QA 未执行。 |
| 导出、追加导入 | `implemented` | JSON 校验并生成独立副本，保留已有布局；不导出 Keychain 或 integrations 目录。 |
| 原生捕获/应用/恢复 | `source tested` | 读取 pinned apps/spacers；测试仅覆盖 tile 序列化。重启后验证、失败回滚已有实现，未实际写入。 |
| 自动保存原生变化 | `implemented` | 用户启用后轮询 pinned tiles；自身切换期间和稳定期不捕获。 |
| 排队切换/防止重复应用 | `implemented` | 原生布局与替换模式共用 mutation queue，应用有进行中状态；实际 restart 链路未执行。 |
| 不可读配置备份 | `implemented` | 先保存恢复副本；副本失败则暂停写入，不修改系统 Dock。 |
| 添加应用/文件/文件夹/链接 | `implemented` | 选择器与外部拖入；原生只允许 app/spacer。 |
| 删除/拖动/复制 | `source tested` | 前后方向排序、唯一 ID fixture 通过；组件副本解除通知开关。 |
| ⌘/⇧ 多选、组移动 | `source tested` | Manager 多选与组排序；`ParityCoreTests` 纯函数 fixture 已包含在 84 项完整测试中。 |
| 小/普通分隔符 | `source tested` | 配置及原生 tile 序列化分别保留大小。 |
| App Folder 应用组 | `implemented` | 名称、颜色、应用成员编辑；点击展开应用选择。 |
| 文件夹名称/颜色/字母 | `source tested` | 绘制 fixture 通过，名称显示可设置；只改变 OpenDock 配置。 |
| 链接名称/SF Symbol/字母/favicon | `implemented` | 用户指定 favicon 读取后缩为 128px PNG，本地缓存；渲染有数据/像素限制。 |
| 图标重置/Symbol 降级 | `implemented` | macOS 13 找不到符号时回退类型图标，编辑器校验符号。 |
| 文件图片/视频预览、Quick Look | `implemented` | QLThumbnailGenerator/QLPreviewPanel；实际格式支持依赖系统。 |
| 文件夹停留展开/Escape | `implemented` | 停留 0.7 秒读取直接内容，Escape 关闭。 |
| Running apps/固定/取消固定 | `implemented` | NSWorkspace regular apps；进程内稳定 ID；菜单和分隔区域拖入。 |
| 应用打开/激活/退出 | `implemented` | 公共 NSWorkspace/NSRunningApplication；真实应用行为未逐一验证。 |
| Calendar 当天图标 | `source tested` | 动态绘制日期 fixture 通过；跨午夜持续刷新待运行验证。 |
| 登录启动 | `implemented` | SMAppService mainApp 注册/取消；未实际启用。 |
| 首次引导/重播 | `implemented` | 三步引导暂存模式/组件，完成才应用；跳过保留设置，重播默认不新建布局。 |
| 设置/关于页面记忆 | `implemented` | 管理器页面持久保存。 |
| URL 自动化 | `source tested` | `opendock://profile/<UUID或编码名称>`；fixture 验证只允许 custom，拒绝 native。 |
| macOS Focus Filter | `implemented` | SetFocusFilterIntent 关联两类布局；实际注册和系统触发待验证。 |
| 自定义全局快捷键 | `implemented` | Carbon；至少两个修饰键，内联冲突/修饰键提示；录制时暂停全局快捷键，失焦/Escape取消，不需要输入监控。 |
| 两指方向/⌘ 滚动切换 | `implemented` | 仅 Dock 范围处理，随边缘调整方向并节流；普通滚轮用于 overflow。 |

## 模式、外观与窗口

范围参考 [Dock 设置](https://dockset.app/manual/choose-your-dock-setup) 与 [外观手册](https://dockset.app/manual/appearance)。

| 功能 | 状态 | 实现与边界 |
| --- | --- | --- |
| 原生/替换/并用三模式 | `implemented` | 替换保存 autohide 三键快照；模式设置已有，未实际改变系统 Dock。 |
| 退出/取消替换恢复 | `implemented` | 恢复保存原值和原缺失键；真实 restore/restart 未执行，不承诺已实测。 |
| 左/底/右、显示器、尺寸 | `implemented` | 设置及可拖动尺寸把手；长度适配屏幕，单个 Custom Dock。 |
| Frosted/Clear/Liquid Glass | `implemented` | 新布局默认 Liquid Glass；管理/设置/弹窗控件使用原生玻璃，阅读区域为稳定卡片；旧 SDK/系统降级，尊重明暗/减少透明度/动态效果。 |
| 图标放大 | `implemented` | hover scale，Reduce Motion 时跳过。 |
| 自动隐藏/隐藏把手 | `implemented` | 到边缘显示、离开延迟；弹窗开启时保持可见。 |
| 桌面组件模式 | `implemented` | 普通应用窗口后方的窗口层级。 |
| Mission Control/原生 Dock 让位 | `implemented` | 已有可见性逻辑；AX Dock 角色依赖系统，多屏/多 Space 待实测。 |
| 全屏 Dock/弹窗 | `implemented` | fullScreenAuxiliary/canJoinAllSpaces；刘海屏、优先级待实测。 |
| 常显 Dock 窗口预留 | `implemented` | AX 调整 focused overlapping window；仅当前 frame 仍匹配自己最后修改时恢复，避免覆盖用户调整。 |
| 点击 focused app 最小化 | `implemented` | 只设置 AXFocusedWindow，不最小化该应用所有窗口；依赖授权/应用支持。 |
| 应用窗口右键菜单 | `implemented` | 名称/状态、单窗恢复/raise，另有退出。 |
| 最小化窗口列表/恢复一项 | `implemented` | 显式开启后 AX 枚举 regular apps；独立于 running apps，不后台请求权限。 |
| 本地持久窗口预览 | `source tested` | PNG/index fixture 覆盖重载/prune/禁用清除；真实捕获需要已有 Screen Recording 授权，未执行。 |
| macOS 14+/13 截图 | `implemented` | 14+ ScreenCaptureKit 单窗；13 CGWindowListCreateImage fallback；无图时窗口符号+应用图标。 |
| Space 恢复 | `implemented` | 公共 AX raise/激活尽力恢复；没有确定性的任意 Space 跳转。 |
| App badges | `source tested` | Dock AX status label 数值/点解析 fixture；不读通知中心或通知正文。 |
| 废纸篓打开/清空 | `implemented` | Finder 打开、状态；清空永久删除确认和 Automation，QA 未清空。 |
| 平滑原生切换 | `implemented` | 14+ 已授权 com.apple.dock wallpaper 暂存，静态图 fallback、Reduce Motion 跳过；新系统 WallpaperAgent/动态壁纸不保证，未 screenshot/restart 验证。 |
| 更新检查/下载/安装 | `implemented` | GitHub Release、SHA-256、结构/codesign 校验；安装按钮触发；覆盖更新未执行。 |

## 组件

目录覆盖官网公开类别；增强细节参考 [0.2.6 changelog](https://dockset.app/changelog)。`implemented` 表示有界面和真实数据/系统 API 调用，不代表权限或账户已经授权。

| 组件/功能 | 状态 | 当前行为 |
| --- | --- | --- |
| Clock | `implemented` | 本机日期时间、格式。 |
| World Clock | `implemented` | IANA 时区。 |
| Calendar | `implemented · account required` | EventKit 日历选择、未来日程、已知会议加入；授权后读取。 |
| Reminders | `implemented · account required` | EventKit 列表、未完成项、点击完成写回。 |
| Focus Timer | `implemented` | 持久时间戳、暂停/恢复、可选通知。 |
| Sticky Note | `implemented` | 本机文字、背景。 |
| Stopwatch | `implemented` | 持久时间戳与暂停状态。 |
| Countdown | `implemented` | 截止时间恢复、可选通知。 |
| Alarm | `implemented` | 显式通知授权后调度；未实际授权验证交付。 |
| Time Progress | `implemented` | 日/周/月/年真实日期区间。 |
| Hydration | `implemented` | 时间、可选 mL、每日汇总，日志/杯量/提醒独立、删除撤销。 |
| Weather | `implemented` | Open-Meteo 搜索/定位、预报、单位/背景/宽度、可选自动刷新。 |
| Now Playing | `implemented · account required` | Music/Spotify AppleEvents 信息/控制/关闭隐藏；未授权实播。 |
| Shortcut | `implemented` | 用户指定 Shortcut 运行，内容由其决定。 |
| AirDrop | `implemented` | 拖入文件/链接、系统分享选择收件人；未设备传输。 |
| Battery | `implemented` | IOPS Mac 电量/供电，设备提供时健康/循环/电压/电流/功率；已连接 HID 外设电量和充电状态，已充满优先，缺失不可用。 |
| Network Activity | `source tested` | 接口计数 delta/地址/up；reset fixture，无抓包。 |
| System Activity CPU | `source tested` | Mach per-core ticks、delta；rollover/首次无样本 fixture。 |
| System Activity 内存/系统 | `implemented` | VM、压力、swap、load average、thermal、uptime。 |
| System Activity 存储扫描 | `source tested` | 显式 Home/Applications/用户 Library 扫描；shared task/取消/Finder；深层、硬链接、符号链接与非法范围 fixture。 |
| Stock | `implemented` | Yahoo chart/search；可选 Alpha Vantage key。名称/范围/成交量/hover/dither；接口可受限，非交易建议。 |
| Watchlist | `implemented` | 多符号、搜索、区间涨跌比较、刷新间隔；同上数据源。 |
| Stripe | `implemented · account required` | Restricted key 只读 Balance/Subscriptions；币种分开，固定订阅 MRR 标为估算，复杂价拒绝错误总额。 |
| Paddle | `implemented · account required` | Billing metrics.read、sandbox、营收/MRR/订阅；服务口径/UTC，ARR = MRR × 12。 |
| Shopify | `implemented · account required` | OAuth+GraphQL 当前订单金额/数目/AOV/商品/来源；分页不足报错，来源不冒充访客流量。 |
| AI Limits | `implemented · account required` | 七 provider，共享连接、Numbers/Rings/Bars、Used/Remaining、顺序与首选额度。 |
| AI Activity | `implemented · account required` | Today/L7/L30/MTD，独立 Limits，本地/账号来源和估算说明。 |
| 网易云音乐（扩展） | `implemented` | 客户端安装/运行/启动与官方链接收藏；没有曲目信息或播放控制。 |
| IBKR（扩展） | `implemented · account required` | 本机可信 HTTPS Client Portal Gateway，手动只读账户/BASE账本/最多10页持仓；默认隐藏金额，未连接实号。 |
| Ollama（扩展） | `implemented` | loopback官方 version/tags/ps 手动采样，展示安装/内存模型、大小与释放期限；不生成/下载/加载模型。 |
| Shadowrocket（扩展） | `implemented` | 安装/运行/启动与系统代理只读摘要；代理状态不等于隧道连接，不切换网络/读取订阅。 |
| 组件复制/稳定弹窗/滚动 | `implemented` | 独立 ID、设置保留、同一项再次关闭、ScrollView、Escape/⌘W；时钟/AI 弹窗关闭流程已有 UI 证据，其余组件及多屏定位仍待实际验证。 |
| 减少闲置查询/重绘 | `implemented` | 系统 shared lease 最后组件卸载停止；暂停 timeline 不每秒重绘；未性能基准。 |

## AI 提供商

对照 [Dockset AI 手册](https://dockset.app/manual/ai-usage)。CLI 版本和账户类型决定数值可用性；没有通过模型任务估计额度，所有 provider 均未实号端到端验证。

| 提供商 | 状态 | 接入与限制 |
| --- | --- | --- |
| Codex | `implemented · account required` | 所选登录 CLI official app-server `account/rateLimits/read`；sessions 数值 token/tool，不是全部 ChatGPT 历史。 |
| Claude | `implemented · account required` | 显式 status-line，保留旧命令、数值 allowance；projects JSONL 活动。Desktop fallback 合成 fixture 通过，显式连接 Cookies/Safe Storage 后只读，后台仅内存会话；客户端 API 非稳定。 |
| Grok | `implemented · account required` | opt-in 只读 auth.json，first-party CLI billing；usage.json 数值按 mtime 分日并标估算。 |
| Cursor | `implemented · account required` | 官方团队 Admin API；opt-in 个人 state.vscdb 单 auth key 查询。个人接口非稳定公开 API，报告 USD cost 不等同账单。 |
| Gemini CLI | `implemented · account required` | opt-in Google OAuth loadCodeAssist/retrieveUserQuota；不 refresh/onboarding；API-key/Vertex 与活动历史不支持。 |
| Copilot | `implemented · account required` | 已登录官方 Copilot CLI SDK account.getQuota；也有官方 billing/gh 客户端额度 fallback（后者非稳定合约）；Unlimited/无 entitlement 不生成百分比。 |
| Antigravity CLI | `implemented · account required` | 显式 status-line allowance/reset，断开只恢复未被用户另改的命令；没有活动历史。 |
| 报告导入、失败/过期缓存 | `implemented` | 数值 schema/来源时间；后台 Keychain 禁授权 UI，重置时间经过不自动假设满额。 |

`PersonalAIAdapters.swift` 的 existing-login adapter、文件选择/明确 opt-in/CLI 连接界面已接入；完整构建证据见验证记录。Claude Desktop 格式/来源/授权边界见 [专门说明](CLAUDE_DESKTOP.md)。

## 细节对照与尚未验证的部分

下列补充细节按当前落盘代码列状态。存在代码不代表客户端账号、权限或系统多 Space 行为已实测；有新增证据时应更新本表。

| 子功能 | 状态 | 现状 |
| --- | --- | --- |
| Claude Desktop Keychain fallback | `implemented · account required` | 显式连接所选 DB 与 Safe Storage；Cookie 只内存，后台五分钟且不读 Keychain。非稳定接口，未实号验证。 |
| 自动寻找 Codex CLI | `implemented` | 用户点击连接后寻找 App bundled CLI、Homebrew/local 候选，手动选择仍可用。 |
| AI popout 单额度显隐 | `implemented` | 每个 allowance 可切换弹窗显示，Dock 首选额度独立。 |
| 取消 provider Show 断开 bridge | `implemented` | Claude/Antigravity 取消显示时恢复旧 bridge（匹配才恢复），Claude Desktop 内存读取停止。 |
| AI Activity 三种独立视图 | `implemented` | Sparkline/Bars/Totals，provider 及时间范围独立。 |
| 股票拖动读值 | `implemented` | hover 检查价格；拖动吸附原始观测两端，比较金额、百分比与跨度，按时间先后处理反向拖动；支持键盘日期选择，4 项 fixture 通过。 |
| 添加组件定位 | `implemented` | Picker添加即关闭；活动Dock短暂显现、滚动到新项目并描边；停用动画时静态反馈。 |
| 跨布局拖拽与取消 | `implemented` | 结构化身份解析当前数据，同布局稳定排序，跨布局独立复制；松开鼠标收尾，原生布局拒绝非应用/分隔符。 |
| 连接设置草稿 | `implemented` | 商业账户名称/域名/模式与天气搜索保留，密钥不写入布局；再次打开恢复设置区域。 |
| 股票页签和曲目信息 | `implemented` | 横向全宽股票页签/名称开Yahoo，长艺人信息延时往返滚动，Reduce Motion静态。 |
| 全屏边缘 dwell | `implemented` | 已有 0.2 秒边缘计时；真实全屏/原生 Dock 优先级仍待运行验证。 |
| 任意 Space 确定跳转 | `unavailable` | 公共 AX 激活为尽力恢复，不使用 private SkyLight/CGS。 |
| Apple WidgetKit 导入 | `unavailable` | 与公开产品范围一样，只支持内置组件。 |
| Dockset 许可/设备激活/付款 | `unavailable` | OpenDock MIT，没有商业许可证兼容。 |
| 13/14/Intel 实机、更新覆盖、实际 Dock 回滚、实号 E2E | `unavailable` | 当前没有此类证据；编译和 fixture 不替代真实验证。 |

当前是扩展版公共 Beta，不应声称“0.2.6 完整逐项兼容已经实测”。权限与缓存见 [隐私](PRIVACY.md)，源码测试见 [Tests/OpenDockTests](../Tests/OpenDockTests)。

集成协议、币种/计费口径、未知 schema 与真实账户边界见 [集成说明](INTEGRATIONS.md)。Gemini 当前支持所选明文 OAuth JSON，不支持未知加密凭据格式；Grok 活动仅支持受识别的 usage.json 数值；Stripe 的折扣/分层/transform 订阅不生成可靠 MRR，收入/净额有独立口径，不能用空值替代。
