# Claude Desktop 额度读取

这是用户明确连接后的只读 fallback，不是 Anthropic 公开、稳定的服务合约。没有访问本机真实 Cookie、token 或 Keychain 做验证；构建和合成 fixture 不能证明实号可用。

实现使用公开的 [Chromium macOS v10 格式源码](https://github.com/chromium/chromium/blob/131.0.6778.204/components/os_crypt/sync/os_crypt_mac.mm) 和 [Cookie v24 域绑定源码](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/net/extras/sqlite/sqlite_persistent_cookie_store.cc) 确认 PBKDF2-HMAC-SHA1、1003 rounds、AES-128-CBC、16 spaces IV 与 SHA256(host) 校验。Swift/CommonCrypto 实现为本项目独立编写，没有复制第三方实现代码。

[Dockset 官方 AI 手册](https://dockset.app/manual/ai-usage) 描述显式授权 Claude Desktop Safe Storage 后读取组织额度的 fallback。本文列出的 SQLite schema 和 `/api/organizations/{uuid}/usage` 是客户端接口范围，官方手册没有承诺其稳定性，也不是 Anthropic 公开 API。未知版本/密文不会尝试猜测密钥。当前只支持 Cookies meta version 23/24、macOS v10。

`ClaudeDesktopUsage.shared.connect(cookieDatabase:)` 只能由显式连接动作调用。它先将用户选择的 Cookies DB 和存在的 WAL 复制到 `0700` 临时目录；文件为 `0600`，读取结束删除。SQLite 只查询 claude.ai 的 sessionKey/lastActiveOrg；没有打开原数据库写入。随后读取 `Claude Safe Storage` 的 Keychain 项，macOS 可能询问权限。[Electron 的说明](https://github.com/electron/electron/blob/main/docs/api/safe-storage.md) 指出 Safe Storage 由系统 Keychain 保护，外部应用读取需要用户允许。

通过后 Cookie 只在当前进程内存；保存的连接仅含所选文件路径，数值缓存仅 allowance/reset/time。`refresh(explicit:false)` 不读取源 DB/Keychain，不出现权限提示，最短 5 分钟刷新一次；`refresh(explicit:true)` 是用户手动刷新并重新读取的动作。OpenDock 重启后，需显式连接/刷新，后台不会自动重建会话。`disconnect()` 清除内存 Cookie、路径和该服务数值缓存，不更改 Claude 登录。

请求仅为 `GET https://claude.ai/api/organizations`（仅缺失 lastActiveOrg 且组织唯一时选取）与 `GET /api/organizations/{uuid}/usage`。使用 sessionKey，不使用挑战 Cookie、验证码或替代登录。HTTP 403、Cloudflare 挑战、多个不明组织、登录过期、未知 schema 或无 quota 都显示不可用，不伪造百分比或自动刷新供应商凭据。Cookie 本身不加入 URL、导出、日志或本地 Keychain 缓存。

独立测试使用 hashlib/OpenSSL 生成的合成密文，检查 PBKDF2 key、v23/v24 解密、错误域/密钥/版本拒绝、会话冲突/过期/CRLF 拒绝、临时 SQLite 过滤/源文件不变、quota 缺失与非有限数值。没有测试 OS 授权、网络客户端或真实账户。实际客户端可能因网站挑战或版本变化拒绝该路径，界面应保留 Claude Code status-line 作为另一来源。
