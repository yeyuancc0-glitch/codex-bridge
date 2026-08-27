# Codex Bridge v0.3.0

本公告只记录相对上一版公开版本 v0.2.1 的用户可见变化。

## 本次更新

- 新增完整可用的 OpenCode ACP Provider：可在 App 中登记和 Probe 本机安装，刷新 ACP 模型目录，选择 Plan/Build 模式，并通过本机审批执行任务、继续任务或中断任务。
- OpenCode 任务可将上一任务的 `provider_session_id` 作为 `submit_task.thread_id` 继续同一会话；Bridge 会校验项目、Provider、安装实例与终态归属，并在私有持久目录保留会话数据库。
- 保持 Codex 默认 `submit_task` 路径与旧客户端字段兼容，同时支持在请求中明确选择 OpenCode Provider。
- 提升任务结果可观测性：任务绑定、最近活动、终态结果和轮询建议可持续查询，短暂安静不会被误报为失败。
- 提升工作台、XPC 和对话流稳定性，完善 Provider 安装管理、任务提交状态和本机审批展示。
- 提升项目与 Direct 执行稳定性：支持外置卷重挂载后的项目身份校验，细化环境能力、嵌套沙箱边界、受控 Git 提交和凭证扫描。
- 提升 MCP 与 Skill 可靠性：全局自定义指令、Skill Action 超时和退出收据更加明确，工具与错误状态保持有界且可诊断。

## OpenCode 使用边界

OpenCode 是用户自行安装的本机运行时，不随 App 打包。当前适配器支持 `1.18.20 <= OpenCode < 1.19.0`，从当前项目根启动 `opencode acp`，模型目录以 ACP `session/new.configOptions` 为准。

`read-only` 映射 OpenCode Plan，`workspace-write` 映射 OpenCode Build。当前 OpenCode ACP 没有 Bridge 级逐任务网络沙箱，`network_access=true` 会被拒绝，网络行为由 OpenCode 原生权限控制。所有远程任务和 ACP 权限请求仍需本机用户批准。

完整安装、MCP 请求示例、任务轮询和排障步骤见：[OpenCode 连接指南](./OPENCODE_CONNECTION_GUIDE.md)。

## 发布包

- `CodexBridge-0.3.0-macos.dmg`
- `CodexBridge-0.3.0-macos.zip`
- `SBOM.spdx.json`
- `SHA256SUMS`

本版本保持 Universal 2（arm64 + x86_64）。由于未配置 Apple Developer ID 证书，发布包未签名、未公证，也没有 Gatekeeper 放行票据。首次打开时请在 Finder 中右键 App 选择“打开”，或在“系统设置 → 隐私与安全性”中选择“仍要打开”。

发布包不包含测试夹具、测试目录、原型、内部架构计划、审查稿、交接文件、个人配置或任何凭据。
