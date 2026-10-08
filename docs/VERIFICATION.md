# 验证清单

本文件记录 OpenDock 初始开发 Beta 的验证边界；构建通过、应用能打开、单元测试通过分别证明不同事情。

## 自动检查

| 检查 | 状态 |
| --- | --- |
| Swift 调试构建 | 已通过（Swift 6.4，macOS 13 编译目标） |
| Swift 单元测试 | 25 项通过，0 失败；布局、导入、持久化、拖拽、计时与原生序列化 |
| `.app --smoke-test` 启动 | 退出码 0；3 个布局、16 种组件、3 个可见窗口初始化成功（不代表视觉验收） |
| 启动前后系统 Dock 固定布局 | 导出 `persistent-apps` 的校验摘要一致，39 个项目未改变 |
| Swift Release 构建与 `.app` 打包 | 本机通过，arm64；后续源码修改需重新打包 |
| 原创图标生成与 `.icns` 转换 | 已通过本机检查 |
| 打包脚本语法检查 | 已通过 `bash -n` |
| 应用签名与 Info.plist 校验 | 本机通过，ad hoc 签名；无 Developer ID 公证 |
| DMG 创建与验证 | 本机通过，`hdiutil verify` 校验成功 |
| 相对 Markdown 链接 | 本机检查通过 |
| 公开文件凭据与私人路径字符串检查 | 已检查拟发布文件，未发现硬编码凭据或私人用户路径 |
| GitHub Actions 执行 | 工作流配置已准备，尚未取得远程执行结果 |

### 打包证据（2026-10-08）

已执行 `./scripts/build-app.sh` 与 `./scripts/package-dmg.sh`：Release 可执行文件为 Mach-O arm64，原创新图标生成与 `iconutil` 转换成功；`plutil -lint` 校验应用 Info.plist 成功；`codesign --verify --strict --verbose=2` 确认 ad hoc 签名有效；`hdiutil verify` 确认生成 DMG 的校验和有效。工具输出的应用标识符为 `io.github.myh66.opendock`，未设置 Developer ID TeamIdentifier。

这些检查证明构建与封装完成。DMG 安装、另一台 Mac 打开、升级后的权限、系统 Dock 实际恢复与真机 UI 仍需独立验收。验证后发生的源码修改需要最终重新打包。本机系统提示 `hdiutil create` 已弃用，但命令执行和校验成功；目前保留该工具以兼容 macOS 13 开发环境。

打包脚本按当前工具链架构构建；本次本机结果为 arm64，CI 架构由 runner 决定，没有生成 Universal Binary。字符串检查用于避免误提交私密数据，不等同于全面安全审计。

## 真机验收

以下项目不能由单元测试替代。未写入明确通过证据的项目均为待验证。

- 初次打开不会修改 Apple Dock；退出和重新打开保留布局。
- 自定义 Dock 位置、隐藏与显示、图标、运行中应用、组件弹窗和菜单栏切换。
- 多显示器、全屏、多 Space、窗口层级与不同缩放比例。
- 全局快捷键冲突、屏幕边缘唤出和键盘可访问性。
- 保存 Apple Dock → 应用新布局 → 验证读取结果 → 恢复备份，包含应用失败后的回滚。
- 损坏 JSON、不支持版本、重复 ID、缺失应用与导入合并。
- 日历／提醒事项允许与拒绝授权；完成提醒事项；音乐自动化的授权提示与拒绝路径。
- 天气联网、超时、空结果；无电池的台式 Mac；Shortcuts 与 AirDrop 的真实系统操作。
- 登录启动在已安装的应用包上生效；移除登录项有效。
- ad hoc 签名 Beta 的升级权限表现与另一个 Mac 的 Gatekeeper 提示。

未经测试的生产发布条件：Developer ID 公证、真实更新安装、App Store 审核、商业和 AI 服务接入。

## 本轮界面验收限制

2026-10-08 已执行打开应用。原生界面检查工具报告 Mac 锁屏，无法取得界面或操作弹窗；已请求用户手动解锁。当前不将界面、自动隐藏、窗口重开或实际权限流程标记为通过。没有在测试中应用或重启系统 Dock。

## 持续集成

首次公开提交 `a2b3163` 的 [GitHub Actions](https://github.com/myh66/opendock/actions/runs/37712219313) 已成功执行构建、25 项测试与应用打包。后续提交的 CI 状态以该提交对应的运行记录为准。CI 使用 `macos-15`，产物采用运行器的架构。
