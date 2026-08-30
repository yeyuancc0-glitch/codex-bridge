# Codex Bridge 详细使用指南

本指南按当前 App、后台 Service、MCP 工具契约和 Provider 适配器编写，适合首次安装、连接 ChatGPT/Qwen、登记本机 Agent，以及日常提交和排查任务。界面名称以当前 Codex Bridge 为准；ChatGPT、OpenAI Platform、Qwen 与各 Provider 的外部页面可能更新，请同时参考其官方文档。

## 1. 先理解四个概念

### 1.1 Chat 客户端与执行 Provider 不是一回事

```text
ChatGPT / Qwen / Bridge 工作台
              │ 提交任务
              ▼
      CodexBridgeService
              │ 选择执行端
      ┌───────┼─────────┬──────────────┐
      ▼       ▼         ▼              ▼
    Codex  OpenCode  DeepSeek Harness  Antigravity
```

- **Chat 客户端**负责理解你的需求并调用 Bridge MCP。
- **Provider**是真正读取项目、运行工具和生成结果的本机 Agent。
- 没有显式填写 `provider_id` 时，任务使用默认 Provider **Codex**。
- OpenCode、DeepSeek Harness 和 Antigravity 必须先在本机登记并启用，任务还要显式选择对应 Provider。

### 1.2 项目、Workbench 默认和单任务请求有优先级

权限优先级为：

```text
项目硬策略 > 用户明确的单任务覆盖 > Workbench 新任务默认
```

- Bridge 控制面只允许任务绑定 `项目` 页面中明确登记的目录；Direct 文件工具会严格校验项目内路径。外部 Provider 以该项目为工作目录，并继续受各自原生 mode/sandbox/权限约束，Bridge 不声称为它们额外提供进程级文件沙箱。
- `工作台` 当前选中的项目，是 ChatGPT/Qwen 省略 `project_id` 时的默认项目。
- `工作台 → GPT/Qwen 新任务 → Read Only / Write` 是跨 Provider 的统一默认权限。
- 只有用户明确要求某次任务覆盖默认权限时，MCP 客户端才应发送 `permission_mode_override=true`。
- 项目禁止写入时，任何任务都不能通过覆盖升级为可写。

### 1.3 凭据不要混用

| 凭据 | 在哪里取得 | 填在哪里 | 不应该填在哪里 |
| --- | --- | --- | --- |
| OpenAI Tunnel Runtime API Key | OpenAI Platform API Keys | Bridge `连接` 页的 `Runtime API Key` | ChatGPT 对话、ChatGPT MCP App、项目文件 |
| ChatGPT Helper 本地 MCP Secret | Bridge 为 ChatGPT profile 单独生成 | Bridge 自动注入 Helper | ChatGPT 表单、Qwen JSON、README、日志 |
| Qwen 本地 MCP Secret | Bridge 为 Qwen profile 单独生成 | Qwen JSON 由 App 自动带入 | ChatGPT、README、日志、手工猜测 |
| Provider 凭据 | Codex/OpenCode/DeepSeek/Antigravity 各自官方环境 | Provider 自己的登录或配置 | Bridge 数据库、项目文档、Issue |

DeepSeek Harness 的 `DEEPSEEK_API_KEY` 属于 Provider 凭据，只放在外部 DSH Profile 的 `.env` 中。Bridge 不读取或保存它。

### 1.4 三种审批也是分开的

1. **远程 Agent 启动审批**：ChatGPT/Qwen 提交 Provider 任务后，默认要在工作台点击“批准启动”。
2. **Provider 执行期审批**：Codex、OpenCode、DSH 或 Antigravity 在运行过程中请求额外工具权限。
3. **Direct 操作审批**：Chat 客户端直接写文件、运行命令或创建本地 Git 提交。

打开“自动批准远程 Agent 启动请求”只影响第 1 类，不会自动批准后两类。

## 2. 安装与首次启动

### 2.1 选择正确架构

Codex Bridge 要求 macOS 14.0 或更高版本。发布包按架构拆分：

- Apple Silicon：选择 `arm64`。
- Intel Mac：选择 `x86_64`。

App、后台 Service 和 Tunnel Helper 必须来自同一架构的发布包。若下载的 App 首次无法直接打开，可在 Finder 中右键 App 选择“打开”，或按 macOS 提示在“系统设置 → 隐私与安全性”确认。

### 2.2 首次授权后台 Service

1. 打开 `CodexBridge.app`。
2. 进入 `概览`，检查“后台常驻 Service”和“本地 MCP 通道”。
3. 如果出现“等待 macOS 登录项批准”，点击“打开系统设置”。
4. 在 macOS 登录项/后台项目页面允许 Codex Bridge。
5. 回到 App，点击“刷新状态”。

如果 App 显示“立即注册后台 Service”，先点击该按钮。关闭窗口不会停止 Service；按 ⌘Q 后是否继续由后文的后台运行设置决定。

### 2.3 从源码构建时的限制

源码 Debug 构建可用于本地 MCP、项目管理和 Provider 开发，但不一定包含经过校验的 OpenAI `tunnel-client`。`连接` 页面显示“Helper 未打包”时，ChatGPT Secure Tunnel 不可用；这不是 Runtime API Key 错误。需要连接 ChatGPT 时，请使用包含 Helper 的正确发布构建。

## 3. App 页面速览

| 页面 | 用途 |
| --- | --- |
| 概览 | Service、本地 MCP、Tunnel 和运行状态总览 |
| 工作台 | 选择远程默认项目/模式，批准、查看、继续或中断任务 |
| 项目 | 登记目录，设置读写/网络策略、Direct 命令和 Skills |
| 日志 | 查看已脱敏的 Service、Tunnel 与 Provider 诊断信息 |
| 连接 | 配置 ChatGPT Tunnel、Qwen 本地 MCP、登记外部 Agent |
| 设置 | Codex/外部 Provider 默认模型、后台策略、Direct 与 MCP 指令 |

## 4. 登记项目并设置权限

### 4.1 添加项目

1. 打开 `项目`。
2. 点击“添加”。
3. 在文件选择器中选择项目根目录。
4. 等待项目出现在列表中，再打开它的详情。

Bridge 会保存规范路径和文件系统身份。不要用项目显示名代替 MCP `project_id`；远程客户端需要显式 ID 时，必须先调用 `list_projects`。

### 4.2 配置项目硬策略

在“访问与执行权限”中选择：

- **读取权限**：拒绝或允许。
- **写入权限**：拒绝、需要本机批准或允许。
- **网络权限**：拒绝、需要本机批准或允许。

保存后，这些策略同时约束 Codex、OpenCode、DeepSeek Harness、Antigravity、Direct Workspace 和 Skill Action 的任务准入与执行模式。允许写入不等于允许任意系统路径：Direct 文件接口会拒绝项目越界、符号链接逃逸和敏感路径；外部 Provider 的进程级文件边界由其原生 mode/sandbox/权限负责。

### 4.3 可选：配置 Direct 命令

只有希望 ChatGPT/Qwen 直接运行项目命令时才需要：

1. 选择“禁止直接执行”“安全模式”或“完全模式”。一般使用安全模式。
2. 在安全模式中登记真实可执行文件、允许参数前缀和相对工作目录。
3. 标记命令是否需要网络、是否属于高风险操作。
4. 按项目需要设置黑名单规则。

Direct 命令使用结构化 argv，不拼接 shell。陌生命令不会因为模型猜到了名称就自动获准。

### 4.4 选择 Workbench 默认

进入 `工作台`：

1. 点击当前项目名称，选择正确的已登记项目。
2. 在“GPT/Qwen 新任务”下选择 `Read Only` 或 `Write`。

切换项目不是装饰性筛选；它会改变远程任务省略 `project_id` 时的实际执行目录。提交前应再次确认。

## 5. 配置本机 Provider

### 5.1 Codex：默认 Provider

Codex 不需要在“本机 Agent 引擎连接”登记。准备方式：

1. 按官方方式安装并登录 Codex/ChatGPT 本机环境。
2. 确认本机 `codex app-server --stdio` 可以由当前用户运行。
3. 打开 `设置 → Codex 执行默认偏好`。
4. 选择默认模型、推理强度、访问权限和可选的 Fast 模式。

Bridge 会从受控位置发现 Codex，但不会读取或导出 Codex 的登录凭据。Codex 是当前唯一支持 Supervisor 和真正 in-flight steer 的 Provider。

### 5.2 OpenCode

当前适配器接受 `1.18.20 <= OpenCode < 1.19.0`。

1. 按 OpenCode 官方方式安装、登录，并确认它自己可以访问模型。
2. 打开 `连接 → 本机 Agent 引擎连接`。
3. 点击“登记 Agent”，选择“OpenCode”。
4. 选择真实 `opencode` 可执行文件，点击“登记并 Probe”。
5. 状态为“可用”后，打开“启用”。
6. 到 `设置 → OpenCode 执行默认偏好` 选择安装实例。
7. 先选择工作台项目，再点击“刷新模型列表”；保存 ACP 返回的精确模型和 effort。

OpenCode 运行 `opencode acp --cwd <项目根>`。`Read Only` 映射 Plan，`Write` 映射 Build；Bridge 使用 OpenCode 原生权限，不额外套一层伪造的网络或文件沙箱。完整说明见 [OpenCode 连接指南](./OPENCODE_CONNECTION_GUIDE.md)。

### 5.3 DeepSeek Harness

DSH 对版本和构建工件做精确校验。当前要求：

| 组件 | 要求 |
| --- | --- |
| DSH tag/package | `dsh-v0.1.1-rc.2` / `0.1.1-rc.2` |
| ACP protocol | `1` |
| Node | `^22.19.0` 或 `>=24.0.0`，不支持 Node 23 |
| pnpm | `11.7.0` |
| ACP SDK | `0.25.1` |

正确登记文件是官方源码构建后的：

```text
<deepseek-harness-source>/packages/examples/acp-demo/lib/bin.js
```

不是 `dsh`、`pnpm dsh web`、源码目录或 Web UI。最小准备流程：

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git deepseek-harness
cd deepseek-harness
git fetch --tags origin
git checkout --detach dsh-v0.1.1-rc.2

node --version
pnpm --version
pnpm install --frozen-lockfile
pnpm run build
test -f packages/examples/acp-demo/lib/bin.js
```

然后准备外部 Profile。运行时强制要求它位于 DSH 源码树之外；为隔离凭据，建议也放在任务项目和 Bridge 仓库之外：

```text
<dsh-profile>/
├── cordis.yml
└── .env
```

- `cordis.yml` 应优先从当前 Bridge 随包模板复制，不要使用上游的泛化示例手工重建；最终以 Bridge 的 Profile 结构校验和 Probe 为准。
- `.env` 与 `cordis.yml` 必须同目录。
- 在 `.env` 中填写 `DEEPSEEK_API_KEY`、主模型 Base URL 和独立的 Web Search Base URL。
- DeepSeek API Key 可在 [DeepSeek Platform API Keys](https://platform.deepseek.com/api_keys) 创建；只在本机 `.env` 中粘贴真实值。

App 中依次执行：

1. `连接 → 本机 Agent 引擎连接 → 登记 Agent → DeepSeek Harness`。
2. 选择 `packages/examples/acp-demo/lib/bin.js`。
3. 点击“下一步”，选择外部 Profile 的 `cordis.yml`。
4. 点击“登记并 Probe”。
5. 状态为“可用”后打开“启用”。
6. 到 `设置 → DeepSeek Harness 执行默认偏好` 刷新模型并保存默认值。模型 ID 来自 ACP 动态目录；effort 来自经过验证的 DSH Profile，当前 thinking 启用时为 `off/low/high/max`，不是按模型由 ACP 单独广告。

DSH 当前只创建新 Session，不支持从历史任务恢复 Session；支持排队继续和“中断当前轮后继续”。完整构建、模板、API endpoint 与故障排查见 [DeepSeek Harness 接入指南](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)。

### 5.4 Antigravity

Bridge 登记的是 `agy` CLI，不是 Antigravity Desktop App：

1. 按 Antigravity CLI 的官方方式安装并完成 CLI 自己的登录。
2. 在终端运行 `agy --version` 和 `agy --help`，确认命令本身可用。
3. 打开 `连接 → 本机 Agent 引擎连接 → 登记 Agent → Antigravity`。
4. 选择真实 `agy` 可执行文件并 Probe。
5. 确认状态为“可用”后打开“启用”。
6. 到 `设置 → Antigravity 执行默认偏好` 刷新模型并选择默认 model/effort。

当前兼容范围为 `1.1.21 <= agy < 1.2.0`。Probe 还会检查当前帮助中是否存在 stream-json、plan、accept-edits、sandbox、conversation、model 和 effort 能力。

- `Read Only` 使用 `--mode plan`。
- `Write` 使用 `--mode accept-edits`。
- Bridge 保留 `agy` 原生 `--sandbox`，不再附加外层 `sandbox-exec`。
- Desktop 的登录/自动执行设置不保证会同步到 CLI；以 `agy` 自己的 CLI 配置为准。
- 当前 headless 输入无法交互回传每个原生工具审批。完全访问只会在本机用户明确保存对应任务权限和网络允许时启用，不能作为默认设置。

### 5.5 理解安装状态

| 状态 | 含义与处理 |
| --- | --- |
| 可用 | 本地文件身份、版本、协议和基本 Session Probe 通过；仍不等于真实账号/API 已验收 |
| 需复核 / `needs_review` | 二进制、Node、manifest、lock、Adapter 或配置身份变化；确认来源后再“接受替换并 Probe” |
| 不可用 | 路径、版本、协议、运行时或配置不符合；查看安全的 `unavailable_reason` |
| 已禁用 | 安装记录存在，但不允许接收任务；打开“启用”后才可提交 |

Provider 更新后不要用旧登记记录静默继续。Bridge 会冻结二进制和相关工件身份，预期更新也需要本机复核。

## 6. 连接 ChatGPT 网页版

ChatGPT 使用 OpenAI Secure MCP Tunnel，不直接访问 Mac 的 `127.0.0.1`。

### 6.1 OpenAI Platform 准备

1. 打开 [OpenAI Platform Tunnels](https://platform.openai.com/settings/organization/tunnels)。
2. 创建 Tunnel 或取得已有 Tunnel ID。Bridge 接受的格式为 `tunnel_` 后跟 32 个小写字母或数字。
3. 打开 [OpenAI Platform API Keys](https://platform.openai.com/settings/organization/api-keys)。
4. 创建 **Restricted** Runtime API Key，只授予 Tunnels `Read` 和 `Use`。

创建/管理 Tunnel 的账号还需要 Tunnels `Read` 和 `Manage` 权限；这与 Helper 日常运行所需的 Read/Use Key 不同。没有入口或权限时，请联系 OpenAI Organization/Workspace 管理员。不要为了运行 Bridge 把管理用 Admin API Key 填进 App。

### 6.2 Bridge 侧

1. 打开 `连接 → 远程 AI 客户端 (OpenAI Secure Tunnel)`。
2. 在 `OpenAI Tunnel ID` 填 Tunnel ID。
3. 在 `Runtime API Key` 填 Restricted Runtime Key。
4. 点击“保存并启动连接”。
5. 等待状态显示 Helper 就绪、Tunnel `ready`，且“远程任务接收”允许。

Runtime Key 会写入 macOS Keychain，不进入 Service SQLite、日志或 Qwen JSON。`tunnel-client` 由 Bridge 自动启动，普通用户不需要在终端长期运行它。

### 6.3 ChatGPT 侧

1. 在 ChatGPT 设置中启用 Developer Mode。
2. 进入 Apps 页面，选择创建自定义 MCP App。
3. 按当前 OpenAI 页面选择 Tunnel 连接。
4. 选择或粘贴与 Bridge 完全相同的 Tunnel ID。
5. 执行工具扫描，再创建/保存 App。上述是当前官方页面的常见流程，实际入口和字段以当前账号与 Workspace UI 为准。

不要在 ChatGPT 侧填写：

- `http://127.0.0.1:<port>/mcp`
- `/mcp` 路径
- Runtime API Key
- `X-Codex-Bridge-Token`

如果页面要求公共 MCP URL，可能是当前表单使用了普通远程 URL 连接；请返回连接方式并对照 OpenAI 当前 Secure Tunnel 指南确认。ChatGPT 套餐、Workspace 管理权限、最新菜单路径、首次测试和常见报错见 [ChatGPT Developer Mode 接入指南](./CHATGPT_DEVELOPER_MODE.md)。

## 7. 连接 Qwen Studio

Qwen Studio 与 ChatGPT 的连接方式不同，它直接访问本机回环 MCP：

1. 打开 Bridge `连接 → 本地 MCP 客户端通道`。
2. 打开“启用 Qwen Studio”。
3. 为 Qwen 选择“只读”或“完整”工具权限。
4. 点击“复制 Qwen JSON 配置”。
5. 在 Qwen Studio 的 MCP 添加页面选择“使用 JSON 添加”。
6. 粘贴并保存，执行工具扫描。

App 复制的结构类似：

```json
{
  "mcpServers": {
    "Codex Bridge": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:<port>/mcp",
      "headers": {
        "X-Codex-Bridge-Token": "<Bridge 自动生成>"
      }
    }
  }
}
```

不要手工猜端口或 Token。JSON 含本机凭据，不能公开。点击“重新生成凭证”后，所有旧 JSON 都会失效；必须在 Qwen 中重新粘贴新配置。

“完整”只表示客户端能看到写入、命令和提交工具，不会绕过项目策略、本机审批或工作区写锁。

## 8. 从 ChatGPT/Qwen 使用任务

### 8.1 第一次连接先做只读发现

建议在新对话中要求：

```text
请调用 bridge_status，列出当前注册项目、已启用 Agent 及可用模型；先不要修改文件。
```

客户端应通过 `list_projects`、`list_agents`、`list_models` 获取真实 ID 和能力，不应猜测项目名、安装 ID、模型或 effort。

### 8.2 提交默认 Codex 任务

当 Workbench 已选对项目时，最小请求只需要：

```json
{
  "prompt": "检查当前项目的构建失败，说明根因并修复相关代码。"
}
```

也可以显式传入 `list_projects` 返回的 `project_id`。不要把项目显示名直接当成 ID。

### 8.3 提交外部 Provider 任务

外部 Provider 必须显式选择：

```json
{
  "provider_id": "deepseek-harness",
  "prompt": "分析当前实现并修复指定问题。",
  "network_access": false
}
```

其他 Provider ID：

- OpenCode：`opencode`
- DeepSeek Harness：`deepseek-harness`
- Antigravity：`antigravity`

`installation_id` 通常可省略；有多个启用安装时再使用 `list_agents` 返回的精确值。只有用户明确指定模型/effort 时才设置 `model_override=true`，并使用当前 Provider 模型目录中的精确 ID。

用户明确要求 Web Search、读取 URL 或调用外部 API 时，应发送 `network_access=true`。这代表明确的网络意图和项目准入，不代表 Bridge 为外部 Provider 提供网络包级隔离。

### 8.4 本机批准启动

默认情况下，远程 `submit_task` 返回：

```text
awaiting_local_approval
```

打开 Bridge `工作台`，核对项目、Provider、权限与任务内容后点击“批准启动”或“拒绝”。远程客户端不能代替本机用户批准。

如果确实希望长期自动启动，可打开：

```text
设置 → 后台运行与远程 Agent 授权 → 自动批准远程 Agent 启动请求
```

该设置默认关闭，并且不批准 Provider 后续工具请求或 Direct 操作。

### 8.5 等待与读取结果

提交后按 `get_task.wait_policy` 建议的时间等待，再调用 `get_task`：

| 状态 | 含义 |
| --- | --- |
| `awaiting_local_approval` | 等待 Mac 本机批准启动 |
| `starting` | Provider 正在启动或建立 Session |
| `running` | 任务运行中；暂时没有 activity 不代表失败 |
| `waiting_for_codex_approval` | 等待 Provider 执行期本机审批；当前持久化状态沿用该名称 |
| `completed` | 成功终态 |
| `failed` | 失败终态，查看 `failure_code` 和摘要 |
| `interrupted` | 已中断终态 |
| `unknown` | Service 重启后失去原运行绑定；这是需要本机复核的非终态，不能伪造恢复 |

只有终态可作为最终结论。终态 `wait_policy.next_action` 可能显示 `read_final_report`，但它只是建议动作名称，不是 MCP 工具；任务完成后仍然读取同一个 `get_task` 中的：

- `result_summary`
- `failure_code`
- `changed_files`
- `recent_activity`
- `thread_id` 或 `provider_session_id`
- `turn_id` 或 `provider_run_id`

### 8.6 继续和中断

| Provider | 继续方式 |
| --- | --- |
| Codex | 同一 Thread/Turn 支持真正的 in-flight steer |
| OpenCode | 当前 prompt 完成后，在同一 ACP Session 中发送排队 prompt；历史续接使用已验证的 `provider_session_id` |
| DeepSeek Harness | 当前任务支持排队继续或“中断当前轮后继续”；不支持历史 Session 续接 |
| Antigravity | 支持精确 Conversation 续接；当前轮内追加仍是 queued steer |

工作台的“补充指令（当前轮完成后继续）”会遵循对应 Provider 语义。中断任务时，控制请求必须绑定当前 `turn_id` 或 `provider_run_id`，以防误操作已切换的运行。

## 9. Direct Workspace 与 Skills

### 9.1 什么时候使用 Direct

只有你明确要求 ChatGPT/Qwen 自己完成以下操作时才使用 Direct：

- 精确读取、写入或 Patch 一个项目文件；
- 运行已登记的项目命令；
- 管理有界进程 Session；
- 创建受控本地 Git commit。

大型编码任务通常应提交给 Provider。Direct 成功响应必须带权威收据，例如文件 SHA、Session ID 或 commit hash；“准备执行”或“没有变化”不代表已修改。

### 9.2 文件与 Git 边界

- 文件路径使用项目内相对路径。
- 写入依赖 revision/SHA，冲突时应重新读取并缩小 Patch。
- `.env*`、私钥、认证文件等敏感路径会被拒绝。
- `direct_git_commit` 不允许 push、amend、reset 或历史改写。

### 9.3 Skills

Bridge 可发现已登记项目中的 `SKILL.md`，但只执行其中明确暴露的 Action。脚本存在或带 shebang 不代表可执行。网络声明、命令权限和本机审批仍受项目策略约束。

## 10. 设置与后台生命周期

### 10.1 退出 App 后是否继续

路径：

```text
设置 → 后台运行与远程 Agent 授权 → 退出 App 后保持后台服务运行
```

- 默认开启：按 ⌘Q 只退出 UI，Service 和已经运行的任务继续。
- 关闭后按 ⌘Q：App 注销 LaunchAgent，Service 会正常关闭 Provider、Direct、MCP 和 Tunnel。
- 单纯关闭窗口不会触发停止。

### 10.2 MCP 自定义指令

`设置` 中的 MCP 自定义指令会作为 MCP Server instructions 提供给 ChatGPT/Qwen。它不是项目规则，也不会自动传入 Codex/OpenCode/DSH/Antigravity prompt。保存后，ChatGPT 通常需要刷新 App/新建对话，Qwen 需要重新连接，才能取得新 instructions。

核心的项目发现、Provider 选择、审批和等待规则已由 Bridge Server 自动提供，不需要在 ChatGPT 中粘贴一大段固定模板。

## 11. 凭据与隐私检查表

- 不在 README、Issue、聊天消息、截图或 Git 中放 API Key、Token、Cookie、`.env`。
- 不向 Bridge 复制 Codex/OpenCode/Antigravity 的认证文件。
- ChatGPT Runtime Key 只填 Bridge“连接”页面。
- Qwen JSON 只粘贴到本机 Qwen Studio；不要公开。
- DSH `.env` 只放外部 Profile，并与 `cordis.yml` 同目录。
- 报错时只分享已脱敏日志，不分享原始认证响应或 `.env`。
- 使用 ChatGPT、DeepSeek 或其他模型服务意味着任务所需内容会发送到相应服务；请按其隐私政策和组织规则评估项目。

## 12. 常见问题

| 现象 | 优先检查 |
| --- | --- |
| 后台 Service 未运行 | 是否批准 macOS 登录项；回到概览刷新；必要时点击“立即注册后台 Service” |
| ChatGPT 连接按钮不可用 | Tunnel ID/Runtime Key 是否为空；当前 App 是否显示 Tunnel Helper 已打包 |
| ChatGPT 扫描不到工具 | Bridge 是否 `ready` 且允许远程任务；ChatGPT 是否选择 Tunnel 并使用同一 Tunnel ID |
| ChatGPT 要求填写公网 URL | 是否误选普通远程 URL，而不是 Secure Tunnel |
| Qwen 无法连接 | 是否启用 Qwen；是否粘贴最新 JSON；凭据或 Endpoint 更新后旧 JSON 是否已失效 |
| 找不到项目 | 是否在“项目”登记；Workbench 是否选择了正确项目；客户端是否使用真实 `project_id` |
| 外部 Provider 不可选 | 是否登记、Probe 为可用、打开启用；任务是否显式填写正确 `provider_id` |
| Provider `needs_review` | 二进制、运行时、manifest/lock 或配置身份是否更新；确认来源后重新 Probe |
| DSH 找不到正确文件 | 选择固定 tag 构建后的 `packages/examples/acp-demo/lib/bin.js`，不是 `dsh` 或 Web UI |
| DSH Probe 成功但 API 失败 | `.env` 是否与 `cordis.yml` 同目录；Key、Base URL、账号额度是否由 Provider 侧有效 |
| DSH 主模型正常但搜索失败 | 检查独立 `DEEPSEEK_SEARCH_BASE_URL` 和 `web_search_20250305` 支持 |
| 任务一直等待 | 是否仍是 `awaiting_local_approval` 或等待 Provider permission；在工作台处理 |
| `project_busy` | 同项目已有写任务或 Direct 写会话；等待或中断正确任务 |
| `unknown` | Service/Provider 是否重启并失去运行绑定；不要把它当作已完成或自动新建替代任务 |
| 暂时没有活动 | 按 `wait_policy` 等待；只有 `get_task` 终态能判断成败 |

## 13. 外部验收边界

以下步骤必须由用户使用自己的账号和本机权限完成，代码测试或 App 打包结果不能替代：

- macOS 后台 Service/项目首次授权；
- Codex、OpenCode、DeepSeek Harness、Antigravity 登录和模型额度；
- OpenAI Tunnel、Runtime Key 与 ChatGPT Developer Mode 权限；
- ChatGPT/Qwen 的真实工具扫描、远程提交与重连；
- Provider 的 Web、MCP、子代理、文件写入和执行期审批；
- Apple Developer Team、Developer ID、公证和正式签名。

专项说明：

- [ChatGPT Developer Mode 接入指南](./CHATGPT_DEVELOPER_MODE.md)
- [OpenCode 连接指南](./OPENCODE_CONNECTION_GUIDE.md)
- [DeepSeek Harness 接入指南](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)
- [Secure Tunnel Helper 技术说明](./TUNNEL_CLIENT_INTEGRATION.md)
