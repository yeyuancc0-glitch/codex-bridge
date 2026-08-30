# ChatGPT Developer Mode 与 Secure MCP Tunnel 接入指南

本指南说明如何把 ChatGPT 网页版连接到本机 Codex Bridge，以及 OpenAI Tunnel ID、Runtime API Key、本地 MCP Token 各自应该放在哪里。OpenAI 网页的菜单和套餐权限会更新；若页面名称与本文略有不同，以 [OpenAI Developer Mode 帮助](https://help.openai.com/en/articles/12584461) 和 [Secure MCP Tunnel 官方指南](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) 为准。

## 1. 连接原理

```text
ChatGPT Web
    │ OpenAI Secure MCP Tunnel
    ▼
OpenAI Control Plane
    │ 长轮询/安全隧道
    ▼
Codex Bridge 内置 tunnel-client
    │ http://127.0.0.1:<Service 保存并复用的本地端口>/mcp
    │ X-Codex-Bridge-Token: <ChatGPT profile 独立的 Keychain Secret>
    ▼
CodexBridgeService MCP
```

ChatGPT 不直接访问 Mac 的 `localhost`，用户也不需要公开端口、配置路由器或长期手工运行 `tunnel-client`。

## 2. 前置条件

开始前确认：

1. `CodexBridge.app` 已安装，后台 Service 在“概览”中正常运行。
2. 已在“项目”页面登记至少一个项目，并设置读取、写入和网络策略。
3. 已在“工作台”选择 ChatGPT 新任务的默认项目和 `Read Only`/`Write` 模式。
4. 当前 App 的“连接”页面显示 Tunnel Helper 已打包/就绪。普通源码 Debug 构建可能不包含 Helper。
5. ChatGPT 账号或 Workspace 允许 Developer Mode 和自定义 MCP App。
6. 你在对应 OpenAI Organization 中有创建/使用 Tunnel 和 API Key 的权限。

OpenAI 当前对账号和 Workspace 的能力有差异：Business 通常由 Workspace 管理员/所有者管理 App，Enterprise/Edu 可通过角色授权，Pro 自定义 App 目前可能仅限 read/fetch。写工具是否可用，以当前 [OpenAI 帮助页](https://help.openai.com/en/articles/12584461) 和 Workspace 管理策略为准。看不到 Developer Mode、Create App 或 Tunnel 时，先联系 Workspace/Organization 管理员，不要通过扩大 Bridge 本机权限规避 OpenAI 侧限制。

## 3. 容易混淆的值

| 名称 | 谁创建 | 用途 | 正确输入位置 |
| --- | --- | --- | --- |
| Tunnel ID | OpenAI Platform | 标识 Secure MCP Tunnel | Bridge App 和 ChatGPT Tunnel App 使用同一个 ID |
| Restricted Runtime API Key | OpenAI Platform | 本机 Helper 认证 OpenAI Control Plane | 只填 Bridge `Runtime API Key` |
| ChatGPT Helper 本地 MCP Secret | Bridge 为 ChatGPT profile 单独生成 | Helper 访问本机 `/mcp` | Bridge 自动注入，用户不读取或手填 |
| Qwen 本地 MCP Secret | Bridge 为 Qwen profile 单独生成 | Qwen 访问本机 `/mcp` | 只由 App 生成的 Qwen JSON 自动携带 |
| ChatGPT 登录会话 | ChatGPT | 登录网页与 Workspace | ChatGPT 自己管理，Bridge 不读取 |

重要边界：

- Runtime API Key 不是 ChatGPT 登录凭据，也不是 Codex、DeepSeek 或 OpenCode Key。
- Runtime API Key 不需要粘贴到 ChatGPT MCP App。
- ChatGPT Helper 与 Qwen 使用彼此独立的 `X-Codex-Bridge-Token` 值。用户不需要从 Keychain 找出任何一个，也不能把它们填进 ChatGPT。
- ChatGPT Tunnel 配置不使用本机 `http://127.0.0.1:<port>/mcp`。

## 4. 在 OpenAI Platform 创建 Tunnel

### 4.1 使用网页创建

1. 登录 [OpenAI Platform](https://platform.openai.com/)。
2. 打开 [Organization Tunnels](https://platform.openai.com/settings/organization/tunnels)。
3. 创建一个 Tunnel，或打开组织中已经分配给你的 Tunnel。
4. 复制 **Tunnel ID**。

Bridge 接受的 Tunnel ID 格式是：

```text
tunnel_ + 32 个小写英文字母或数字
```

例如：

```text
tunnel_0123456789abcdef0123456789abcdef
```

上面的值只是格式示例，不可直接使用。不要写成旧格式 `tun_...`。

创建和管理 Tunnel 的成员通常需要 Tunnels `Read` 与 `Manage` 权限。没有 Tunnels 页面或创建按钮时，请让 Organization 管理员通过 [Organization Roles](https://platform.openai.com/settings/organization/people/roles) 分配合适角色。

### 4.2 CLI 管理不是普通用户必需步骤

[OpenAI Secure MCP Tunnel 官方指南](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)中的外部管理 CLI 流程可能使用 Admin API Key。Codex Bridge 不实现该管理流程，也不需要普通用户自行运行管理 CLI；该 Key 不是 Bridge Runtime Key，不能填进 Codex Bridge。

## 5. 创建最小权限 Runtime API Key

1. 打开 [Organization API Keys](https://platform.openai.com/settings/organization/api-keys)。
2. 创建新的 API Key。
3. 选择 **Restricted** 权限。
4. 对 Tunnels 只授予：
   - `Read`
   - `Use`
5. 不授予运行 Helper 不需要的管理、模型或其他资源权限。
6. 创建后立即复制一次，并准备粘贴到 Bridge App。

Runtime Key 的具体字符串前缀不是稳定契约，不要依赖 `sec_`、`rtk_` 等猜测。Bridge 只校验它非空、没有首尾空白且是有界可打印文本；真正的权限和有效性由 OpenAI Control Plane 判断。

安全要求：

- 不要写入 shell 历史、项目 `.env`、README、Issue、日志或截图。
- 不要通过聊天把 Key 发给 ChatGPT。
- 如果怀疑泄露，立即在 OpenAI Platform 撤销并创建新 Key，然后在 Bridge 重新保存。

## 6. 在 Codex Bridge 中配置 Tunnel

1. 打开 `CodexBridge.app`。
2. 进入 `连接`。
3. 找到“远程 AI 客户端 (OpenAI Secure Tunnel)”中的“Secure MCP 隧道”。
4. 在 `OpenAI Tunnel ID` 输入完整 Tunnel ID。
5. 在 `Runtime API Key` 粘贴刚创建的 Restricted Runtime Key。
6. 点击“保存并启动连接”。

Bridge 的处理方式：

- Tunnel ID 和启用状态存入 Service 设置。
- Runtime API Key 通过 XPC 交给后台 Service，并写入 macOS Keychain。
- Key 不写入 SQLite，不出现在状态响应、Qwen JSON 或普通日志中。
- Service 校验随包 Helper 后自动执行诊断、启动和健康检查。

### 6.1 如何判断 Bridge 侧真的就绪

至少同时确认：

- Helper：就绪。
- Tunnel lifecycle：`ready`。
- 远程任务接收：允许。
- 当前绑定 Tunnel ID 与 Platform 中一致。

状态含义：

| 状态 | 含义 |
| --- | --- |
| `starting` | Helper 正在启动 |
| `authenticating` | 进程已运行，但尚未证明 Control Plane 认证成功 |
| `connecting` | Control Plane 有新鲜响应，本地 MCP 还未严格 ready |
| `ready` | Tunnel 与本地 MCP 均 ready，可接收远程请求 |
| `degraded` | 曾经 ready，当前健康或认证证据已经过期 |
| `failed` | 配置、Key、Helper 或网络失败 |
| `stopped` | 用户断开或 Service 停止 |

“Helper 就绪”只说明二进制存在；只有 `ready` 且远程任务接收允许，才说明 Bridge 侧入口已经开放。ChatGPT 侧的工具扫描和调用仍需单独验证。

### 6.2 断开、重连和清除

- “断开隧道”：停止当前连接，但不等同于删除 Platform Tunnel。
- “重新连接”：使用已保存的 Tunnel ID 和 Key 重新启动。
- “清除配置”：停止连接，删除本机保存的 Tunnel ID/启用状态，并从 Keychain 删除 Runtime Key；不会删除 OpenAI Platform 上的 Tunnel 或 API Key。

## 7. 在 ChatGPT 打开 Developer Mode

根据当前 OpenAI UI，常见路径为：

1. 打开 [chatgpt.com](https://chatgpt.com)。
2. 进入 `Settings → Apps → Advanced settings`。
3. 打开 Developer Mode。
4. 回到 Apps 页面，选择创建 App；在受管 Workspace 中，也可能从 `Workspace settings → Apps → Create` 进入。

如果页面没有这些入口：

- 检查当前选择的是个人空间还是组织 Workspace。
- 检查 Workspace 管理员是否允许自定义 MCP App。
- 检查你的角色是否有 Create/Developer Mode 权限。
- 检查当前套餐是否只开放 read/fetch，或尚未开放自定义 App。

## 8. 在 ChatGPT 创建 Tunnel App

1. 点击 `Create` 或“创建 App”。
2. 名称填写 `Codex Bridge` 或自定义名称。
3. 按当前 OpenAI 页面选择 Tunnel 连接。
4. 选择或粘贴与 Bridge 中完全相同的 Tunnel ID。
5. 执行工具扫描。
6. 检查发现的工具，再创建/保存 App。

这是根据当前 OpenAI 官方页面整理的常见流程，不是 Bridge 本地代码能够保证不变的网页契约；实际入口、字段名和可用能力以当前账号、Workspace 与官方帮助为准。

Tunnel 方式下，ChatGPT 通过 Tunnel ID 查找远端连接。不要额外填写：

```text
http://127.0.0.1:<port>/mcp
/mcp
Runtime API Key
X-Codex-Bridge-Token
```

如果表单要求 MCP Server URL，可能是当前表单处于普通远程 URL 连接。请返回连接方式并对照 OpenAI 当前 Secure Tunnel 指南确认。Bridge Helper 内部已经把 Tunnel 请求转发到本机 `/mcp`，Tunnel 流程本身不需要用户在 ChatGPT 重复配置本地路径。

### 8.1 Server Instructions

Bridge 会在 MCP 初始化时自动提供项目发现、Provider 选择、本机审批、任务等待和结果读取规则。ChatGPT 页面如果提供 Server Instructions 字段，可以留空或只写你的组织级补充要求；不需要复制一套固定的 Bridge 工具调用模板。

Bridge `设置 → MCP 自定义指令` 中保存的内容也会作为 Server instructions 提供给 ChatGPT/Qwen。修改后建议刷新 App 连接或新建对话。

## 9. 在 Bridge 选择 ChatGPT 工具权限

路径：

```text
连接 → 本地 MCP 客户端通道 → ChatGPT/Qwen 工具权限
```

为 ChatGPT 选择：

- **只读**：状态、项目、文件读取、模型、Agent、任务查询等发现工具。
- **完整**：在只读基础上暴露任务提交、任务控制、Direct 文件/命令/Git 和 Skill Action。

工具数量和 Schema 会随 Bridge 版本演进，以 ChatGPT 当次 Scan Tools 结果为准。切换权限后，需要在 ChatGPT 重新扫描或刷新 App。完整模式不会绕过项目硬策略、写任务互斥、本机审批或 Provider 原生权限。

## 10. 第一次连通性测试

### 10.1 只读测试

新建 ChatGPT 对话并启用 Codex Bridge App，然后输入：

```text
请先调用 bridge_status，再列出当前注册的项目和已启用的 Agent。不要修改文件。
```

预期：

- `bridge_status` 能读取 Service 状态。
- `list_projects` 返回已登记项目和不透明 `project_id`。
- `list_agents` 返回外部 Provider 安装、可用性、启用状态和模型摘要。

如果 ChatGPT 只复述问题但没有调用工具，检查对话中是否启用了刚创建的 App，以及 Workspace 是否允许 MCP tool calls。

### 10.2 默认 Codex 任务

先在 Bridge 工作台选好项目和 `Read Only`/`Write`，再输入：

```text
请通过 Codex Bridge 提交一个 Codex 任务：检查当前项目 README 的本地链接，只报告问题，暂时不要修改。
```

正常流程：

1. ChatGPT 调用 `submit_task`；省略 `provider_id`，因此使用 Codex。
2. 返回 `awaiting_local_approval`。
3. 你在 Bridge 工作台核对内容并点击“批准启动”。
4. 任务进入 `starting`、`running`，必要时出现 Provider 审批。
5. ChatGPT 按 `wait_policy` 调用 `get_task`。
6. 只有 `completed`、`failed` 或 `interrupted` 等终态才可下最终结论。
7. 结果从 `get_task.result_summary`、`failure_code`、`changed_files` 等字段读取。

当前 MCP 工具目录没有独立的 `get_final_report`。终态 `wait_policy.next_action` 可能显示 `read_final_report`，但它只是建议动作名称，不是 MCP 工具；仍应从同一个 `get_task` 读取结果。

### 10.3 写任务

1. 在项目策略中允许写入或设置“需要本机批准”。
2. 在 Workbench 选择 `Write`。
3. 在 ChatGPT 明确说明允许修改的范围和验收条件。
4. 在工作台批准任务启动，并处理后续 Provider 权限请求。
5. 终态后检查 `changed_files`、结果摘要和本地 Git diff。

同一项目同一时间最多一个活动 `workspace-write` 任务。第二个写任务可能返回 `project_busy`；只读任务可以并行。

### 10.4 外部 Provider 示例

DeepSeek Harness 必须显式选择：

```json
{
  "provider_id": "deepseek-harness",
  "prompt": "检查当前项目的构建脚本并说明问题。",
  "network_access": false
}
```

OpenCode 使用 `opencode`，Antigravity 使用 `antigravity`。有多个安装时再传 `list_agents` 返回的 `installation_id`。只有用户明确要求覆盖模型或权限时，才使用 `model_override` 或 `permission_mode_override`。

## 11. 任务等待、继续与中断

### 11.1 不要把安静当作失败

`get_task` 会返回 `wait_policy`。请按建议的时间再次查询，不要因为：

- `updated_at` 暂时不变；
- `recent_activity` 为空；
- Provider 长时间思考；
- Tunnel 暂时断开；

就自行宣布任务失败。Tunnel 断线只影响新的远程请求，不会自动取消已经在本机运行的任务。

### 11.2 继续语义

- Codex 支持当前 Turn 的真实 steer。
- OpenCode、Antigravity 和 DSH 的常规补充指令是当前 prompt 完成后的 queued steer。
- OpenCode 与 Antigravity 可在严格匹配的历史 Session/Conversation 上续接。
- DeepSeek Harness 当前不支持历史 Session 续接，但工作台支持中断当前轮后继续。

### 11.3 Service 重启

- 尚未启动且仍等待本机批准的远程任务会继续等待。
- 已经 starting/running、但重启后失去 Provider 运行绑定的任务会诚实标记为 `unknown`。
- Bridge 不会创建一个新运行冒充旧任务恢复。

## 12. 安全验收建议

建议用无敏感内容的方式验证：

- 请求读取一个未登记目录下的自建测试文件，确认 Bridge 拒绝路径越界；不要拿真实 SSH 私钥或系统认证文件测试。
- 提交一个只读任务，确认项目写策略没有被升级。
- 提交一个受控小写任务，检查 Workbench 本机启动审批和 Provider 审批是分开的。
- 在任务运行时关闭 ChatGPT 页面或临时断开 Tunnel，确认本机任务继续，并在恢复连接后用 `get_task` 查询。
- 使用 Direct Git 提交前检查 staged diff，确认返回真实 `commit_hash`，并验证没有 push/amend。

## 13. 故障排查

### 13.1 Bridge 中“保存并启动连接”不可用

检查：

- Tunnel ID 是否为空或不是 `tunnel_` + 32 位小写字母/数字。
- Runtime Key 是否为空或含首尾空格。
- 当前 App 是否显示 Tunnel Helper 已打包。

### 13.2 `invalid_tunnel_configuration`

重新从 Platform 复制 Tunnel ID，删除首尾空格；不要使用旧 `tun_...` 格式。Runtime Key 不要手工添加引号或换行。

### 13.3 `tunnel_helper_unavailable`

当前 App 没有包含可用 Helper，或 Helper 身份/摘要校验失败。换用正确的正式发布包；单纯重建 Debug App 或重新粘贴 Key 无法修复缺失的 Helper。

### 13.4 `keychain_unavailable`

允许 App/Service 使用当前用户的 macOS Keychain，回到连接页重新保存 Runtime Key。不要改成把 Key 存明文文件。

### 13.5 一直是 `authenticating` 或变成 `failed`

检查：

- Runtime Key 是否属于正确 OpenAI Organization。
- Restricted Key 是否有 Tunnels Read + Use。
- Key 是否已撤销或过期。
- Tunnel 是否仍存在、Tunnel ID 是否对应同一个组织。
- 本机代理、防火墙或网络是否能访问 OpenAI Control Plane。

### 13.6 Bridge 已 ready，但 ChatGPT Scan Tools 失败

检查：

- ChatGPT App 是否选择 **Tunnel**，而不是远程 URL。
- ChatGPT 中 Tunnel ID 是否与 Bridge 完全一致。
- 当前 ChatGPT Workspace 是否能访问该 Tunnel。
- Workspace 管理员是否允许 Developer Mode、自定义 App 和所需工具类型。
- 修改 Bridge 工具权限后是否重新 Scan Tools。

### 13.7 能扫描只读工具，但不能提交任务

在 Bridge `连接 → 本地 MCP 客户端通道` 将 ChatGPT 工具权限改为“完整”，然后在 ChatGPT 重新扫描。若套餐/Workspace 只允许 read/fetch，即使 Bridge 选择完整，OpenAI 侧也可能不允许写工具。

### 13.8 任务停在 `awaiting_local_approval`

这是默认安全行为。打开 Bridge 工作台，核对项目、Provider、权限和 prompt 后点击“批准启动”。ChatGPT 无法代替本机批准。

### 13.9 清除配置后仍在 Platform 看到 Tunnel

正常。Bridge“清除配置”只删除本机设置和 Keychain Runtime Key，不会删除 OpenAI Platform 上的 Tunnel/API Key。需要彻底撤销时，请在 Platform 分别删除或撤销。

## 14. 官方参考

- [OpenAI Secure MCP Tunnels](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
- [tunnel-client End User Guide](https://github.com/openai/tunnel-client/blob/master/docs/end-user-guide.md)
- [ChatGPT Developer Mode](https://help.openai.com/en/articles/12584461)
- [OpenAI Platform Tunnels](https://platform.openai.com/settings/organization/tunnels)
- [OpenAI Platform API Keys](https://platform.openai.com/settings/organization/api-keys)
- [OpenAI Organization Roles](https://platform.openai.com/settings/organization/people/roles)
- [Codex Bridge 详细使用指南](./USER_GUIDE.md)
- [Secure Tunnel Helper 技术说明](./TUNNEL_CLIENT_INTEGRATION.md)

OpenAI 账号、Tunnel、Runtime Key、ChatGPT App 创建和真实工具调用必须由用户使用自己的账号完成。Bridge 的代码测试、Helper 健康检查或本地 App 状态不能代替 OpenAI 侧验收。
