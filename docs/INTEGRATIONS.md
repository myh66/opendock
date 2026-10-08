# 外部数据连接

OpenDock 的收入、行情和 AI 组件读取真实来源。未连接、权限不足、网络失败或不认识的响应显示明确错误，保留上次成功的数据。测试使用人工构造的数值 fixture；没有使用本机私人账户、商业密钥或个人 AI 登录进行端到端验证。

## 商业账号

在 Stripe、Paddle 或 Shopify 组件的弹出面板中添加账号，输入名称和所需凭据。账号名称、环境和店铺域名属于本地元数据；密钥写入 macOS Keychain。多个组件可以引用同一账号。重新选择账号、日期、币种或指标后刷新报告。

| 服务 | 最小权限与接入 | 数据口径 |
| --- | --- | --- |
| Stripe | `rk_live_` / `rk_test_` restricted key：Balance Read + Subscriptions Read | Balance payment activity 减退款／冲正，收入为费用前，净额扣费；按币种分别计算。固定 active / past_due 订阅规范化到月，试用和按量计费排除。复杂折扣、分层、数量转换或不完整订阅使 MRR 不可用，收入仍保留。 |
| Paddle Billing | Live / Sandbox 匹配的 API key，仅 `metrics.read` | 官方 Revenue / MRR / Active Subscribers 指标。净营收为税费后、退款及拒付前；主余额币种，UTC 日期。ARR = MRR × 12。 |
| Shopify | 同一组织的已安装应用，Client ID + Client secret，`read_orders`；固定 `*.myshopify.com` 域名 | client_credentials 换取短期 token 后查询 GraphQL Admin 2026-07；按店铺时区。current order total 含税／运费，含未支付、全额退货订单，排除测试、取消订单。超过 10,000 订单拒绝显示不完整总额。 |

Stripe 的订阅趋势从连接后的每日快照开始积累；不会回填并不存在的历史。Shopify 商品显示订单中的剩余数量，渠道显示订单来源；订单接口并不提供真实访客流量。删除账号凭据不会替供应商注销账号或撤销远端密钥，请按供应商控制台需要操作。

官方 API 依据：[Stripe Balance Transactions](https://docs.stripe.com/api/balance_transactions/list)、[Stripe Subscriptions](https://docs.stripe.com/api/subscriptions/list)、[Paddle Revenue](https://developer.paddle.com/api-reference/metrics/get-metrics-revenue/)、[Paddle MRR](https://developer.paddle.com/api-reference/metrics/get-metrics-monthly-recurring-revenue/)、[Paddle Active Subscribers](https://developer.paddle.com/api-reference/metrics/get-metrics-active-subscribers/)、[Shopify Client Credentials](https://shopify.dev/docs/apps/build/authentication-authorization/client-credentials-grant)、[Shopify Orders](https://shopify.dev/docs/api/admin-graphql/latest/queries/orders)。产品口径参考 Dockset 的 [Stripe](https://dockset.app/manual/stripe)、[Paddle](https://dockset.app/manual/paddle)、[Shopify](https://dockset.app/manual/shopify) 手册；实现独立编写。

## 股票与自选列表

搜索并选择交易代码，可切换范围、查看价格与成交量，在图表悬停读取时间点，并选择比较代码。Yahoo Finance 数据可能延迟，其网页 chart / search 接口没有稳定公开 API 保证；服务拒绝时显示错误。Alpha Vantage 是可配置的备用来源，API key 放在 Keychain；完整历史、盘中行情取决于用户计划。日线响应未提供币种时不假定为 USD。

数据来源：[Yahoo Finance](https://finance.yahoo.com/)、[Alpha Vantage API documentation](https://www.alphavantage.co/documentation/)。行情仅是供应商返回的数据；组件不执行交易。

## AI 额度与活动

各供应商连接是全局共享的本地设置。组件可选择与排序供应商、选择额度并切换视觉样式。活动日期支持 Today、L7、L30、MTD：L7 包含今天与前六天，MTD 从本机月份开始。刷新失败保持此前的额度及其时间，重置时间经过不会推断成“满额”。

| 来源 | 实际接入 | 范围与边界 |
| --- | --- | --- |
| Codex | 用户选择已登录 `codex`，官方 app-server `account/rateLimits/read`；另选 sessions 文件夹 | 五小时／周窗口取服务报告。本地 token_count 取累计差值去重；活动只覆盖这台 Mac。API-key 登录可能无订阅额度。 |
| Claude | 选择 projects 数值日志；状态栏 feed 接收 `rate_limits`；明确连接 Claude Desktop Cookies 作备用 | status-line hook 连接前保留旧配置，断开时只在设置仍匹配时恢复。状态栏缺失或超过五分钟时才用桌面备用；后台不触发新授权。上下文窗口占比不是账号额度。 |
| Grok | 明确选择 `auth.json` 并允许只读现有登录，官方 CLI billing credits 接口；另选 sessions 文件夹 | 仅包含 coding credits，不合并购买余额或按需上限。新版 `usage.json` 只取数值 ledger；按文件最后修改日归属，属于本地每日估算，不是精确每日消耗。未知旧格式不猜测 tokens。 |
| Cursor | 团队只读 Admin API；个人明确选择 `state.vscdb`（只查询一个 auth key）并允许读取 | 个人仪表盘 quota / usage-events 是非稳定客户端接口。账号范围的 token API 报告费用不等于账单。分页总数变化或超过上限拒绝不完整活动；缺失字段不意味着零。 |
| Gemini CLI | 明确选择 Google OAuth `oauth_creds.json` 并允许只读；官方 `loadCodeAssist` + `retrieveUserQuota` | 逐模型 remainingFraction。不支持 API-key / Vertex；不执行 onboarding、模型调用或刷新过期凭据。启用 encrypted credential storage 的 CLI 需另行支持，当前文件入口不能读取该 Keychain 格式。 |
| GitHub Copilot | 选择已登录 Copilot CLI，公开 SDK `account.getQuota`；已登录 `gh` 客户端接口为兼容回退；可配置官方个人计费 API key | SDK 协议 3、生成类型标记 experimental。不创建会话。gh `/copilot_internal/user` 无稳定公开 REST 合约；无限／零占位额度不生成进度条。官方个人计费 API 只提供用量，不提供包含上限。 |
| Antigravity CLI | 官方 status-line quota feed，连接后重新打开 `agy` 并 `/usage` | 接收 remaining_fraction / reset_time，只有额度，没有活动历史；断开条件恢复旧配置。 |

AI Activity 只接 Codex、Claude、Cursor、Grok；Gemini、Copilot、Antigravity 为额度来源。日志分析不会保存 prompts、messages、tool arguments、邮箱或 transcript 内容。读取现有登录必须由用户在组件中明确选择，凭据仅在内存中用于对应固定服务地址，OpenDock 不自动刷新或改写供应商登录文件。Copilot / Codex CLI 自身的登录、网络和本地诊断行为由供应商控制。

协议依据：[Codex app-server](https://developers.openai.com/codex/app-server/)、[Claude statusline](https://code.claude.com/docs/en/statusline)、[Grok official billing source](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs)、[Grok persisted usage source](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/session/usage_file.rs)、[Gemini official server source](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts)、[Gemini quota types](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts)、[Cursor Admin API](https://prod.cursor.com/docs/account/teams/admin-api)、[Copilot SDK quota](https://github.com/github/copilot-sdk/blob/main/docs/features/usage-and-billing.md)、[Copilot SDK transport source](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts)、[GitHub billing usage API](https://docs.github.com/en/rest/billing/usage)、[Antigravity statusline](https://antigravity.google/docs/cli/statusline)。对齐口径参考 [Dockset AI usage manual](https://dockset.app/manual/ai-usage)。

## 数值报告导入

当供应商版本未返回已支持的协议时，可主动导入自己的数值报告。导入不会替代真实账号连接的验证，也不会宣称未知来源已支持。JSON 合约为 `version: 1`、`provider`（枚举 raw value）、ISO `updated_at`；`limits` 行包含 `id`、0–100 的 `used_percent`、可选 `resets_at`。Activity 支持的供应商可另提供 `activity` 行：`id`、`session`、ISO `timestamp`、非负 `input_tokens` / `output_tokens` / `cached_tokens` / `tool_calls` / `requests`，可选 `cost_usd`。未知字段不进入缓存，行 ID 和 session 哈希后保存。

缓存位于 `~/Library/Application Support/OpenDock/integrations/`：文件名哈希、目录 0700、文件 0600。报告缓存与服务密钥、供应商凭据分开；常规布局导出不含服务密钥。详见 [隐私说明](PRIVACY.md) 和 [验证记录](VERIFICATION.md)。
