# 隐私与数据流

OpenDock 不需要 OpenDock 账户，没有分析遥测、云端布局同步或自动上传布局服务。用户连接的组件会读取本机系统、工具或对应服务的数据。本说明描述当前代码，不表示已使用真实账号验证所有服务。

## 本机数据

主目录为 `~/Library/Application Support/OpenDock/`。配置与缓存包含私人信息；文件权限不等同内容加密。

| 数据 | 保存位置 | 触发与保留 |
| --- | --- | --- |
| 布局、应用/文件路径、名称、快捷键、便签、计时、饮水记录、天气配置/缓存、favicon PNG | `layouts.json` | 编辑或状态变化时原子保存；可导出用户选择的 JSON。 |
| 不可读配置恢复副本 | `layouts-unreadable-<UUID>.json` | 无法解码时保留；备份失败暂停保存，副本可能包含旧私人内容。 |
| 原生 Dock 偏好快照 | `native-dock-backup.plist` | 主动 apply 前原子写，`0600`。每次 apply 覆盖为当次前状态，只有一层恢复，不是永久的首次原始布局；restore 不覆盖快照。 |
| 替换模式拥有的偏好 | `replacement-mode.plist` | 保存 autohide、delay、time-modifier 原值/原缺失状态；恢复仅这些键，成功后删除快照。 |
| 窗口缩略图 | `window-previews/<SHA256>.png`、`index.json` | 显式开启最小化窗口且已有屏幕录制授权才捕获；目录 `0700`，PNG/index `0600`、原子写。关闭窗口 prune，禁用清除本服务文件。 |
| 集成元数据、数值历史、连接路径 | `integrations/<SHA256>.json` | 显式连接后保存更新时间、数值、来源/路径；目录 `0700`，文件 `0600`，报告不含供应商 access token。 |
| CLI status-line 恢复字段 | `integrations/` 中对应备份 | 显式连接 Claude/Antigravity 时保存旧 statusLine 字段与路径；旧自定义命令原文可能本身含私人信息。 |
| 用户输入服务密钥 | Keychain service `io.github.myh66.opendock.integrations` | 明确连接 Stripe/Paddle/Shopify、Cursor Admin、GitHub billing、Alpha Vantage 时保存；不写布局、数值缓存、导出或错误日志。 |
| Claude Desktop 会话 | 仅进程内存；路径/数值在 integrations | 显式连接/手动刷新读取所选 Cookies 和 Claude Safe Storage；Cookie 不复制进自有 Keychain，重启后需手动连接。 |

窗口 PNG 包含对应窗口的可见内容，可能包括私人文档。它是本机旧快照，用于最小化后的预览，并可在 OpenDock 重启后读取。关闭窗口/应用后身份失效的条目会清除；最小化期间不能保证截图更新。禁用功能取消待捕获任务并删除缓存，文件系统删除错误或备份服务可能使副本继续存在。

文件预览用 QLThumbnailGenerator，OpenDock 只做内存缓存；系统 Quick Look 可能使用自己的缓存。Quick Look 仅在用户选取操作时打开。文件夹弹窗读取该目录直接内容，不自动递归扫描磁盘。

## 权限和系统写入

| 权限/操作 | 用途 | 请求时机 |
| --- | --- | --- |
| Accessibility | 窗口标题/状态、focused window 最小化、单窗恢复、窗口空间预留、Dock badge labels | 仅点击允许访问；普通读取只检查已授权状态。 |
| Screen Recording | 单窗预览；macOS 14+ 可选切换 wallpaper frame | 仅点击允许屏幕录制；预览/transition 先 preflight，没有授权跳过。 |
| Calendar/Reminders | EventKit 选择日历/列表、完成提醒写回 | 主动连接并授权后；内容不写布局 JSON。 |
| Automation | Music/Spotify 信息与控制，Finder 清空废纸篓 | 用户连接/控制或确认清空时由 macOS 管理。 |
| Notifications | 闹钟、计时完成、饮水提醒 | 显式开启；已调度通知可能在关闭弹窗后交付。 |
| Location | 天气当前位置 | 点击“使用当前位置”；不持续跟踪，选定坐标保存用于预报。 |
| 登录启动 | SMAppService mainApp 注册/取消 | 用户切换开关，失败显示状态。 |

辅助功能不录制键盘输入。Carbon 热键不请求输入监控。Badges 只解析 Dock status label 数值或点，不读取通知中心数据库或通知正文。窗口标题/位置只在内存用于匹配，缓存文件名为窗口身份散列。

原生布局 apply/restore 与替换模式会写系统 Dock 偏好并重启当前用户 Dock；capture 只读。布局应用只写 `persistent-apps`，其他偏好/文件夹区保留；native backup 恢复保存的 pinned 状态。两类写入共用串行队列，替换偏好有独立快照。QA 未实际修改或重启用户 Dock，源码描述不是已实测恢复的证明。

平滑切换仅筛选 com.apple.dock 的负层级 wallpaper window，不承诺覆盖新系统 WallpaperAgent/动态壁纸；失败读取静态系统 wallpaper 文件；不请求权限、不录音，过渡图像只在内存。Mission Control 隐藏依赖系统公开窗口名称识别；不同版本/语言可能不提供这些名称，尚未多 Space 实测。窗口预览用单窗 filter，不采集整个桌面；macOS 13 已授权时用 CGWindowListCreateImage 单窗 fallback，无图显示符号。

## 显式扫描和系统指标

存储扫描只在点击开始后运行，范围为用户 Home、`/Applications` 或用户 `~/Library`。Shared service 持有任务，关闭弹窗继续，可取消；结果只在进程内存，包含名称、路径、已分配/逻辑大小。没有上传、自动定时扫描或删除按钮，点击在 Finder 显示。

扫描不跟随发现的符号链接，硬链接去重，累计深层大小；界面最多三层、30,000 节点。保护目录、取消、细节上限显示不完整，不请求 Full Disk Access。结果不是整个磁盘的完整占用。

CPU/Mach ticks、VM 内存、压力/swap、load average、thermal/uptime、IOPS/设备电池和接口计数来自本机公开 API。挂载相关本地监控组件后启用共享 sampler，最后一个卸载停止。网络组件显示接口地址/计数 delta，不抓包或读取网络内容；设备缺失字段保持不可用。

## AI 与商业连接

用户选择日志文件夹后，Codex/Claude/Grok 活动解析才读取日志。解析会在内存读 JSONL，但落盘只保留数值 counters、散列标识和日期，不保存提示词、对话、工具参数或原始 transcript。Grok session 数值按文件 mtime 分日，标明估算；Codex 本机活动不是全部 ChatGPT 历史。

Codex 启动用户所选登录 CLI app-server，仅 initialize 和 account/rateLimits/read，不创建模型任务。Claude/Antigravity bridge 只有连接按钮才修改设置，payload 缩为额度/重置时间后保存；已有命令接收原 stdin、输出保留。断开只在当前命令仍匹配 OpenDock 安装命令时恢复旧字段，不覆盖用户后续更改。

Claude Desktop fallback 只在显式连接/手动刷新读取用户所选 Cookies DB 与 Keychain `Claude Safe Storage`，可能出现授权提示；只查询 sessionKey/lastActiveOrg。为避免修改供应商 DB，先将选定 DB/存在的 WAL 暂存于 owner-only 临时目录，读取结束删除；临时副本仍包含原数据库内容。Cookie 只保留当前进程内存，后台不读源数据库或钥匙串，最多每五分钟请求一次。数值报告和所选路径可保存，凭据不导出/落盘；重启后需手动重新连接，断开清除内存会话。详情及非稳定接口边界见 [Claude Desktop](CLAUDE_DESKTOP.md)。

Gemini/Grok/Cursor 已有登录读取要求用户选文件并明确 opt-in。令牌在内存用于自己的服务，不复制到数值缓存，不改写/刷新过期登录。Cursor SQLite readonly 固定查询一个 auth key，不遍历数据库。Copilot 用用户所选已登录 gh 固定参数查询，不打印 token。个人 Cursor/gh Copilot 接口非稳定公开合约，可能因版本变化不可用。另可用户选择已登录的官方 Copilot CLI，headless RPC 只查询 account.getQuota，不发送模型消息；接口能力缺失则保留可见错误。导入报告不等于实时连接。

商业服务只读：Stripe Balance/Subscriptions、Paddle Metrics、Shopify token exchange/GraphQL。账户/商品名称、图表和连接元数据可进入本地缓存；原始响应解析时在内存。组件标注数值口径/不足，不执行收费、充值、订单或订阅修改。

后台 Keychain 查询禁止授权 UI；需要授权的读取留给手动连接/刷新。集成 HTTP 使用 HTTPS host allowlist，拒绝 credential redirect，不打印请求头、credential URL 或 response body。供应商会接收获授权的请求身份、IP 和查询参数。启用自动刷新后按间隔请求；关闭自动刷新/断开连接停止对应后台读取。

## 网络接收方

0.3.0 的新增组件中，Ollama 仅在点击连接或刷新后请求本机 loopback 的 `version/tags/ps`，不发送提示词、不生成内容或下载模型。IBKR 仅访问用户填写的本机可信 HTTPS Client Portal Gateway，读取账户、账本与持仓；不保存登录凭据、不执行交易，数值仅保留组件内存，账户 ID 与网关地址会随布局导出。两者拒绝重定向，使用独立会话且不走系统代理。

网易云组件保存用户主动填写的官方公开歌曲/歌单/专辑/艺人链接和名称；点击打开才交给浏览器，不读取网易云登录或私人播放记录。Shadowrocket 仅读取应用安装/运行状态和系统默认代理配置摘要，不读订阅、节点或 PAC 内容，不修改网络设置，代理启用状态不能证明 Shadowrocket 隧道已连接。

| 接收方 | 数据/触发 |
| --- | --- |
| `geocoding-api.open-meteo.com` | 主动城市搜索文本。 |
| `api.open-meteo.com` | 选定坐标/单位/预报字段；更新或已配置自动刷新。 |
| 用户指定 favicon URL | 图标按钮的图片请求；128px PNG 本地缓存，使用不含凭据网址。 |
| `query1.finance.yahoo.com`、`query2.finance.yahoo.com` | 股票符号、搜索和范围。 |
| `www.alphavantage.co` | 符号/范围、用户 Keychain key。 |
| `api.stripe.com` | Restricted key、日期/分页查询。 |
| `api.paddle.com`、`sandbox-api.paddle.com` | Key、期间/指标。 |
| 验证的 `*.myshopify.com` | Client credentials、只读 GraphQL；不接收任意 shop host。 |
| `api.cursor.com` | Admin key 和查询。 |
| `cursor.com` | opt-in 现有登录，个人额度/活动。 |
| `cloudcode-pa.googleapis.com` | opt-in OAuth token、项目/quota。 |
| `cli-chat-proxy.grok.com` | opt-in xAI 登录、billing credits。 |
| `api.github.com` | GitHub billing token 或已有 gh Copilot 登录；只读查询。 |
| `claude.ai` | 显式连接 Desktop 会话后组织/usage 查询；Cookie 仅内存，不自动刷新登录。 |
| GitHub Release API/下载 CDN | 更新检查/下载；配置自动更新后也会请求，安装仍由按钮触发。 |
| 链接、Shortcut、分享目标 | 用户打开/运行/分享后由目标应用处理。 |

天气来自 [Open-Meteo](https://open-meteo.com) 和其独立 [条款/隐私说明](https://open-meteo.com/en/terms)。第三方许可、额度、收费、账号条款独立于 MIT License。OpenDock 不代理 API 请求或托管用户密钥。

## 撤销和清理

系统设置撤销 OS 权限，关闭最小化窗口清理预览。断开商业账号删除该 Keychain 项和连接元数据；旧数值缓存可能保留，卸载后可按需要删除 integrations。Claude/Antigravity 取消显示也会断开 bridge；Claude Desktop 停止内存读取。其他显示开关不等于注销供应商账户，独立断开动作仍可用。

布局、快照、副本、集成缓存不做内容加密。导出前检查路径、便签、饮水、坐标和网址；iCloud/其他备份由用户自行配置。卸载前恢复系统 Dock、断开 status-line，保留恢复快照直至成功。删除数据/恢复步骤见 [使用说明](USAGE.md)。
