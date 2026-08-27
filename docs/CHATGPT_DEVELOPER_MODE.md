# ChatGPT Developer Mode 接入与全流程验收指南

本指南为 **Codex Bridge** 的用户侧完整接入手册，详细指导如何将 **ChatGPT 网页版**（通过 OpenAI 官方 Secure MCP Tunnel）安全连接到本地运行的 Codex Bridge，并在本地环境中完成真实端到端任务执行与验收。

---

## 目录
- [一、 前置准备与环境要求](#一-前置准备与环境要求)
- [二、 获取 OpenAI Secure Tunnel 凭据](#二-获取-openai-secure-tunnel-凭据)
- [三、 在 Codex Bridge App 中配置连接](#三-在-codex-bridge-app-中配置连接)
- [四、 在 ChatGPT 网页端配置 MCP 应用](#四-在-chatgpt-网页端配置-mcp-应用)
- [五、 端到端连通性测试与使用示范](#五-端到端连通性测试与使用示范)
- [六、 真实闭环验收核对表 (Checklist)](#六-真实闭环验收核对表-checklist)
- [七、 常见问题与故障排查 (FAQ)](#七-常见问题与故障排查-faq)

---

## 一、 前置准备与环境要求

在开始接入前，请确保满足以下条件：

1. **Mac 运行环境**：
   - 搭载 macOS 14.0 (Sonoma) 或更高版本的 Mac（推荐 Apple Silicon 芯片）。
   - 本地已安装并登录 **Codex 桌面端**（或系统终端 PATH 中具备可执行的 `codex` 命令且 `codex app-server` 能正常启动）。
2. **ChatGPT 账号权限**：
   - 拥有支持 **Developer Mode（开发者模式）/ 自定义 MCP Connectors** 的 ChatGPT Plus / Team / Enterprise 账号。
3. **注册本地项目**：
   - 打开 `CodexBridge.app`，在“项目”页面中点击添加你要操作的本地项目根目录（例如 `~/Projects/my-app`）。
   - 项目路径、设备 ID 与 Inode 会被 Bridge 安全捕获并严格校验。

---

## 二、 获取 OpenAI Secure Tunnel 凭据

Codex Bridge 通过 OpenAI 官方开源的 `tunnel-client` 建立安全的双向端到端隧道，无需公网 IP 或配置内网穿透端口。

1. 登录 [OpenAI 开发者平台](https://platform.openai.com/) 或对应的 OpenAI MCP Tunnel 管理后台。
2. 创建或查看你的 **Secure MCP Tunnel**：
   - **Tunnel ID**：类似 `tun_xxxxxxxxxxxx` 的字符串。
   - **Restricted Runtime Key**：为该 Tunnel 分配的专属受限运行密钥（通常形如 `sec_xxxx` 或 `rtk_xxxx`）。
3. *安全提示*：请妥善保存该 Key，**绝不要**将其提交到 Git、写入公共聊天框或截图中。

---

## 三、 在 Codex Bridge App 中配置连接

1. 打开 **CodexBridge.app**，进入 **连接 (Connections)** 面板（或在初次启动向导中）：
   - 在连接模式中选择 **Secure MCP Tunnel**。
2. **填入凭据**：
   - **Tunnel ID**：输入你的 Tunnel ID。
   - **Runtime Key**：粘贴你的受限运行密钥。
   - *安全说明*：该 Key 将直接存入 macOS 系统级 **Keychain（钥匙串）**，Bridge 不会将其记录在 SQLite 数据库、日志或明文文件中。
3. **启动并检查就绪状态**：
   - 点击 **启动 / 连接**。
   - 观察连接状态指示轨，确认以下指标全部亮起绿色：
     - `Local MCP`：本地 HTTP/Streamable Gateway 监听正常
     - `Tunnel Helper`：后台 `tunnel-client` 守护进程已成功拉起
     - `Health / Ready`：回环健康检查通过，远程准入 (Admission) 已开放
4. **选择工具暴露模式**（按需）：
   - **只读模式 (Read-Only)**：暴露 11 个只读工具（查看项目、读取文件、列出模型与线程等，适合检索与审查）。
   - **完整模式 (Full-Action)**：暴露 22 个工具（包含任务提交、Direct 文件改写、受控 Git 提交与安全命令执行）。

---

## 四、 在 ChatGPT 网页端配置 MCP 应用

1. **打开开发者设置**：
   - 在浏览器中打开 [chatgpt.com](https://chatgpt.com)。
   - 点击左下角头像 → **Settings（设置）** → **Connected apps / Developer Mode / MCP**。
2. **添加新的 MCP 连接**：
   - 点击 **Add New MCP Server / Create App**。
   - **Name（名称）**：填入 `Codex Bridge`（或自定义名称）。
   - **Transport Type（传输类型）**：选择 **OpenAI Secure Tunnel**。
   - **Tunnel ID**：填入与 Bridge App 中完全相同的 Tunnel ID。
   - **Endpoint Path**：填入 `/mcp`。
3. **填写 Server Instructions（推荐提示词）**：
   - 在应用设置的 **Server Instructions**（或 Custom Instructions）中粘贴以下最佳实践提示词，以规范 ChatGPT 的工具调用流程：

```text
Before starting any coding task, call list_projects to discover registered workspaces, list_agents to inspect explicitly registered local providers, and list_models to inspect Codex models. Never invent or guess identifiers.
For long-running tasks, call submit_task with a structured prompt, project_id, and explicit requirements. Omit provider_id for the default Codex path; set provider_id="opencode" only when the user explicitly requests the registered OpenCode provider.
If direct edits or commands are explicitly requested by the user, use direct_write_project_file, direct_apply_project_patch, or direct_exec_project_command and inform the user that local desktop approval may be required.
Periodically check progress with get_task. Do not claim completion until get_task reports a terminal status; then call get_final_report for the structured final report.
```

4. **保存并测试扫描工具**：
   - 保存配置，点击 **Test Connection / Scan Tools**。
   - 验证工具列表已正确加载；具体工具数量以当前 Bridge 返回的扫描结果为准。

---

## 五、 端到端连通性测试与使用示范

在 ChatGPT 开启新的对话，并确保顶部已启用 `Codex Bridge` MCP 连接。

### 场景 1：基础连通性与项目发现（只读测试）

在对话中输入：
> *“请列出当前 Codex Bridge 注册的本地项目和可用的 Codex 模型。”*

**预期结果**：
1. ChatGPT 调用 `list_projects` 工具，返回你在 Bridge App 中添加的项目列表（含项目名称、相对目录、只读/写权限状态）。
2. ChatGPT 调用 `list_models` 工具，返回本机 Codex 支持的模型列表（如 `gpt-5-codex`、`o3-mini` 等）及其 reasoning effort 档位。

---

### 场景 2：通过本地 Codex 执行任务（推荐核心路径）

在对话中输入：
> *“在项目 `<你的项目名>` 中，帮我检查一下 `README.md` 的格式，并在末尾添加一段使用说明。”*

**预期结果**：
1. ChatGPT 自动组装任务契约并调用 `submit_task`。
2. **CodexBridgeService** 接收到任务，并在后台启动独立的 Codex 执行会话。
3. **桌面端反馈**：
   - 打开 `CodexBridge.app`，在工作台中可以看到该任务正处于实时运行状态。
   - 会话流以打字机式实时呈现 Codex 的推理思考过程（可折叠）与工具执行进度。
4. ChatGPT 端通过 `get_task` 按返回的 `wait_policy` 轮询进度，进入终态后调用 `get_final_report` 获取结构化最终报告。

---

### 场景 3：通过 OpenCode Provider 执行任务（可选）

先按照 [OpenCode 连接指南](./OPENCODE_CONNECTION_GUIDE.md) 在 Bridge 中登记、Probe 并启用 OpenCode。确认 `list_agents` 返回 `provider_id: "opencode"`、`availability: "available"`、`enabled: true` 和 `task_submission_enabled: true`。

最小请求示例：

```json
{
  "project_id": "<list_projects 返回的项目 ID>",
  "provider_id": "opencode",
  "prompt": "检查项目结构并总结当前构建问题。",
  "network_access": false
}
```

如需本次明确选择模型或权限模式，再使用 ACP 返回的精确模型 ID，并设置 `model_override: true`、`permission_mode_override: true`。`read-only` 映射 OpenCode Plan，`workspace-write` 映射 OpenCode Build；当前 OpenCode ACP 不接受 `network_access: true`，网络行为由 OpenCode 原生权限控制。继续已有 OpenCode 会话时，将 `get_task` 返回的 `provider_session_id` 作为下一次 `submit_task.thread_id`；新会话省略 `thread_id`。OpenCode 任务不要携带 `skill_name` 或 Supervisor 字段。

任务提交后通常先进入 `awaiting_local_approval`，本机用户在 Bridge 工作台批准后才会启动 OpenCode。使用 `get_task` 查看 `provider_session_id`、`provider_run_id`、`recent_activity`、`execution_model`、`execution_effort`、`permission_mode` 和任务阶段；进入终态后调用 `get_final_report` 获取结构化报告。OpenCode 的 `steer_task`/`interrupt_task` 将 `get_task` 返回的 `provider_run_id` 填入 `expected_turn_id`。

---

### 场景 4：直接文件修改与本地桌面审批（Direct 工具路径）

在对话中明确要求 ChatGPT 直接修改文件：
> *“请直接使用 direct_write_project_file 工具，为当前项目新建一个 `test_demo.txt` 文件，内容为 `Hello Codex Bridge`。”*

**预期结果**：
1. ChatGPT 调用 `direct_write_project_file`。
2. **Mac 桌面审批弹出**：
   - `CodexBridge.app` 立即弹出桌面审批面板，展示待写入的绝对路径、变更文件内容摘要与安全签名校验（Payload Digest）。
   - 用户可点击 **允许 (Allow)** 或 **拒绝 (Deny)**。
3. **执行结果**：
   - 若点击允许：文件安全写入磁盘，ChatGPT 收到成功写入的 receipt（含当前文件的 SHA256）。
   - 若点击拒绝：文件保持不变，ChatGPT 收到 `approval_denied` 结构化拒绝提示。

---

## 六、 真实闭环验收核对表 (Checklist)

完成全部配置后，可通过下表逐项核验系统的健壮性：

- [ ] **项目隔离验证**：尝试让 ChatGPT 读取项目目录之外的绝对路径（如 `/etc/passwd` 或 `~/.ssh/id_rsa`），确认被 Bridge 严格拒绝并返回 `path_denied`。
- [ ] **断线安全验证**：在任务执行过程中，关闭网络或断开 Tunnel 连接，确认本地后台 Service 中的 Codex 任务**继续正常执行**，未被中断。
- [ ] **UI 解耦验证**：在任务执行过程中彻底退出 `CodexBridge.app` 桌面窗口，确认后台任务不中断；重新打开 App 后能无缝重新拉取到任务最新进度。
- [ ] **写冲突互斥验证**：同一项目中有一个正在执行的写任务时，尝试提交第二个写任务，确认 Bridge 自动排队或拒绝并提示 `project_busy`，确保工作区不发生并发写冲突。
- [ ] **安全提交验证**：使用 `direct_git_commit` 进行受控 Git 提交，确认敏感文件（如 `.env*`、私钥）不会被误提交，且拒绝破坏性的 `push` 或 `amend` 操作。

---

## 七、 常见问题与故障排查 (FAQ)

### Q1: ChatGPT 提示 "Could not connect to MCP server" 或无法扫描到工具？
- **排查步骤**：
  1. 检查 `CodexBridge.app` 的“连接”页面，确认 `Local MCP` 与 `Tunnel Helper` 是否均为绿色已连接状态。
  2. 确认 ChatGPT 填写的 **Tunnel ID** 与 Bridge App 中的完全一致（无前后空格）。
  3. 确认 ChatGPT 填写的路径是 `/mcp`，且不要在 URL 中填写 `localhost` 或包含本地 secret。

### Q2: 任务提交后，ChatGPT 提示 `project_busy`？
- **原因**：当前项目已有一个活动的写入任务或正在运行的 Direct 命令会话。
- **解决**：等待前一个任务执行完毕，或在 App 中手动终止前一个任务。

### Q3: 为什么 ChatGPT 无法直接批准 Codex 的危险操作？
- **设计原则**：Bridge 坚持**本地唯一授权（Local-Only Approval）**原则。无论是 ChatGPT、外部客户端还是内置的 Supervisor，均无权代替 Mac 本地用户做安全决定。所有危险文件修改或高危命令必须在 Mac 桌面弹窗中由用户人工点击批准。

### Q4: 重启电脑后，Bridge 会自动恢复吗？
- **机制说明**：`CodexBridgeService` 作为 macOS 标准 LaunchAgent 运行，如果开启了“开机自启”，系统重启登录后服务会自动启动并准备就绪。
