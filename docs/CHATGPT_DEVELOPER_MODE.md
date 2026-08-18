# ChatGPT Developer Mode 接入与验收

本文是 Codex Bridge 的用户侧接入手册。它描述真实接入所需的人工步骤和可观察结果，不把本地 fake fixture 或无凭证测试当作 ChatGPT 端验收。ChatGPT、OpenAI Tunnel 和 Codex 登录的界面会变化，界面名称不一致时以当前产品中的同义入口为准。

## 1. 前置条件

开始前确认：

- macOS 14 或更高版本，Codex CLI 已安装并能启动 `codex app-server`；
- Codex Bridge 已完成首次启动，项目已通过应用内目录选择器注册；
- Codex 登录由应用内向导完成。不要把 `auth.json`、Cookie 或任何 Token 复制到聊天、日志或仓库；
- Supervisor 的每个隔离 HOME 也只能由该 HOME 内的 Codex app-server 通过官方 ChatGPT 登录接口完成配置。Bridge 不复制或读取主 HOME、其他任务 HOME 或 `auth.json`；因此首次启用新的隔离会话可能需要用户再次在系统浏览器完成登录。
- ChatGPT 账号具备 Developer Mode / 自定义 MCP 应用权限；
- 若使用 Secure MCP Tunnel，已经在 OpenAI 平台创建仅用于 Tunnel 的 Restricted Runtime Key，并知道 Tunnel ID。

## 2. 在 Bridge 中配置连接

### Secure MCP Tunnel（推荐）

1. 在 Bridge 的 Connections 或首次运行向导中选择 **Secure MCP Tunnel**。
2. 输入 Tunnel ID 和 Restricted Runtime Key。Runtime Key 只写入 macOS Keychain，Bridge 不会在日志、支持包或 Codex/Luna 请求中回显它。
3. 等待界面同时显示本地 MCP 就绪、helper 就绪、健康检查通过和远程提交可用。只有 `/readyz`、匹配的 helper peer PID 和新鲜 control-plane poll 全部通过，才算远程 admission 开放。
4. 若健康检查失败，先在 Bridge 中处理明确的认证或配置错误。认证失败不会自动重试；普通 helper 意外退出最多按 `1s/2s/4s` 退避重建三次。

Bridge 的 Tunnel 模式对 ChatGPT 使用固定的 `/mcp` 路径和非秘密静态请求头。不要把本地 path secret、Runtime Key 或 helper 管理 socket 地址填入 ChatGPT。

### Manual HTTPS（替代）

只有在你已经有强认证、无重定向的公网 HTTPS MCP 地址时才使用此模式。地址必须是 HTTPS 的 `/mcp`，不得包含用户信息、query 或 fragment；Authorization 值由应用保存并用于连接测试。公网端点、证书、访问日志和防刷边界由你自行负责。

### Local（仅开发）

Local 模式只监听 `127.0.0.1`，适合 MCP Inspector 和本机回归，不能让 ChatGPT 网页访问。Local 显示为已就绪时不代表远程提交可用。

### 手动暂停接收

菜单栏和 Connections 页面中的 **暂停接收新任务** 只关闭新的远程提交，不会停止本地 MCP 或中断正在运行的任务。该选择写入本机数据库，连接替换、睡眠恢复和应用重启后仍保持；恢复操作也必须等待当前 transport 重新通过健康检查。

## 3. 在 ChatGPT 网页添加开发者应用

1. 打开 ChatGPT 网页的 **Settings**，进入 **Apps / Connectors**（不同版本可能显示为 Developer Mode 或自定义 MCP 应用）。
2. 打开 Developer Mode，选择创建自定义应用或 MCP Server。
3. 使用官方 Secure MCP Tunnel 选项时，选择与 Bridge 中完全相同的 Tunnel ID。若界面要求 MCP 地址，使用官方流程显示的 Tunnel `/mcp` 地址；不要填 `localhost`，也不要填 Bridge 的 path secret。
4. 使用 Manual HTTPS 时，填入完整 HTTPS `/mcp` 地址和对应强认证信息。仅在你确认该端点为自己的服务时保存。
5. 保存后只授予这个应用所需的工具访问权限。Bridge 不向 ChatGPT 暴露 Codex 审批工具；高风险审批仍只能在 Mac 本地完成。
6. 在应用的连接测试或工具列表中确认能看到工具目录。工具数量应为：只读模式 11 个；完整模式 22 个。完整模式的 Direct 文件编辑与受控命令工具（`direct_write_project_file`、`direct_edit_project_file`、`direct_apply_project_patch`、`direct_manage_project_path`、`direct_exec_project_command`、`direct_read_command`、`direct_write_stdin`、`direct_interrupt_command`）只应在你明确要求 ChatGPT 直接修改文件或运行命令时调用，默认工作仍走 `submit_task` 交给本机 Codex。

不要在 ChatGPT 的 Server Instructions、对话或截图中粘贴 Runtime Key、Authorization 值、项目绝对路径或 Codex 登录信息。

## 4. 推荐 Server Instructions

将以下短指令放入开发者应用的 Server Instructions。它约束调用顺序，但不会绕过 Bridge 的本地策略或审批：

```text
Before starting any task, call list_projects, list_threads when continuing work, and list_models. Never invent identifiers. For write tasks, submit a structured task contract with goal, requirements, non-goals, constraints, and acceptance criteria. After submission, tell the user whether local approval is pending. Use get_task rather than repeatedly submitting the same work. Do not claim completion until get_final_report returns a terminal result.
```

## 5. 验收顺序

### 当前无凭证、本地可验收的部分

在 Bridge 中使用 Local 模式或测试专用 Tunnel fixture，可以验证：

1. `list_projects` 只返回已注册项目的脱敏元数据；
2. `list_threads`、`list_models` 返回真实边界内的有界结果，标识符不会由 ChatGPT 猜测；
3. 相对路径文件读取拒绝绝对路径、符号链接逃逸和默认敏感路径；
4. 连接替换失败会关闭远程 admission，重新配置成功后才恢复；
5. `get_task` 在 Supervisor 不可用时明确返回 `supervisorState = unavailable`；Supervisor 默认推荐 Luna，但允许使用当前目录中的其他用户选择模型。

当前仓库的 `productionReviewAvailable` 固定为 `false`。因此，在没有完成真实 Supervisor 隔离认证前，`submit_task` 被拒绝是预期的 fail-closed 结果，不是 ChatGPT 配置错误。

### 真实凭证化验收（需要用户在本机授权）

完成 Codex 登录、隔离 HOME 配置和 Restricted Runtime Key 后，按以下顺序逐项记录结果：

1. ChatGPT Developer Mode 的连接测试成功，Bridge 记录到匹配 Tunnel ID；
2. `list_projects`、`list_threads`、`list_models` 成功；
3. 用已注册项目、真实模型 ID 和 `list_models` 给出的 effort 提交最小只读任务；
4. Bridge 本地确认出现后再允许执行；
5. 通过 `get_task` 观察计划、事件序号、Supervisor 状态和终态；
6. 只有 `get_final_report` 返回绑定同一 task/project/thread/turn/generation 的终态报告，才在 ChatGPT 中宣称完成；
7. 断开 Tunnel 后确认本地任务不被停止、新的远程提交被拒绝；恢复 Tunnel 后确认重新通过严格健康检查；
8. 用恶意 fixture 验证 Supervisor 不能读取项目根、用户目录或联网，也不能批准审批请求。
9. 验证双执行模式：请 ChatGPT 直接改写一个项目文件（`direct_write_project_file`）时，Bridge 本地出现“仅本次允许/拒绝”审批，批准后文件原子写入；拒绝后文件不被修改。再请 ChatGPT 直接运行一个已登记命令（`direct_exec_project_command`），确认命令在独立进程组内有界运行、输出可读、可中断，且 Codex 写任务与 Direct 命令在同一项目互斥。

Supervisor 认证的顺序必须是：创建任务隔离 HOME，启动仅允许出站网络的认证 app-server，用户在系统浏览器完成官方登录，收到匹配的 `account/login/completed` 成功通知并由 `account/read` 核验，然后停止认证进程，再用同一 HOME 启动完全禁网的只读 Supervisor 进程。

任何一步失败都保留明确的 unavailable/failed 事实，不用自然语言或旧 generation 证据替代成功结果。

## 6. 常见问题

| 现象 | 处理 |
| --- | --- |
| ChatGPT 看不到工具 | 先确认 Bridge 的 MCP listener 和 Tunnel `/readyz`，再重新运行应用连接测试；不要反复更换 Tunnel ID。 |
| 连接成功但 `submit_task` 被拒绝 | 检查 Bridge 是否仍在 Supervisor production gate；当前版本在真实隔离认证完成前会有意拒绝。 |
| Tunnel 认证失败 | 在 Bridge 中重新输入受限 Runtime Key；不要读取或复制 Keychain 内容，也不要把 Key 放进命令行。 |
| 工具返回旧任务状态 | 使用 `get_task` 的游标重新读取；任务事实来自 EventStore，不以 ChatGPT 对话缓存为准。 |
| Tunnel 断线后本地任务停止 | 这是不符合设计的结果，应记录任务 ID、event sequence 和连接状态后报告；断线只应关闭新的远程 admission。 |

## 7. 发布前证据清单

- 真实 Codex ChatGPT 登录完成，且没有导出凭证；
- 隔离 HOME 下的默认 Luna 或用户选择 Supervisor 模型 initialize、model/list、thread/start、turn/start 和恶意读写/联网回归通过；
- Restricted Runtime Key、Tunnel ID、helper doctor、ready、metrics 和断线重连证据已记录；
- ChatGPT Developer Mode 完成 16 工具目录和最小任务闭环；
- 连续 checkpoint、existing Thread recovery、finalization recovery 通过；
- Developer ID 签名、公证、staple 和干净 Mac Gatekeeper 验收通过。

在以上证据齐全前，README 和应用界面必须继续显示 pre-release / unavailable，不能把本地测试结果描述为生产可用。
