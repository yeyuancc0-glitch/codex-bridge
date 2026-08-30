# DeepSeek Harness 接入指南

本指南说明如何取得 Bridge 当前支持的 DeepSeek Harness（DSH）、构建正确 ACP 可执行文件、准备外部 `cordis.yml` 与 `.env`、在 App 中登记并从 ChatGPT/Qwen 提交任务。

DSH 的 Provider ID 固定为：

```text
deepseek-harness
```

省略 `provider_id` 时 Bridge 使用 Codex，不会自动改用 DSH。

## 1. 当前锁定版本

Bridge 对 DSH 的源码工件、Node、manifest、lock、ACP 版本和 Profile 结构做精确校验。Bridge 不读取 Git 元数据；表中的官方 tag 是用户取得正确源码版本时应 checkout 的来源标识。

| 组件 | 要求 |
| --- | --- |
| 官方源码 tag | `dsh-v0.1.1-rc.2` |
| package version | `0.1.1-rc.2` |
| ACP protocol | `1` |
| Node | `^22.19.0` 或 `>=24.0.0` |
| pnpm | `11.7.0` |
| ACP SDK | `0.25.1` |

Node 版本解释：

- 支持 Node 22.19.0 及更高的 22.x。
- 支持 Node 24.0.0 及更高版本。
- 不支持 Node 22.18.x 或 Node 23.x。

不要登记其他 DSH tag 后期待 Bridge 忽略工件差异。Bridge 实际校验 package/lock/runtime/protocol，而不是用 Git tag 自证来源；升级适配器需要代码、模板、fixture 与兼容门一起更新。

## 2. 获取官方源码

只从 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 获取源码：

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git deepseek-harness
cd deepseek-harness

git fetch --tags origin
git checkout --detach dsh-v0.1.1-rc.2
git describe --tags --exact-match
```

最后一条命令应输出：

```text
dsh-v0.1.1-rc.2
```

不要把第三方重新打包的同名脚本、全局 `dsh` 命令或其他分支当作当前兼容版本。

## 3. 准备 Node 和 pnpm

先确认当前终端使用的版本：

```bash
node --version
pnpm --version
```

示例合格结果：

```text
v22.19.0
11.7.0
```

或 Node 24+ 与 pnpm 11.7.0。请按 Node/pnpm 官方方式安装兼容版本；不要仅在交互式 shell alias 中伪装版本。

DSH 的 ACP entrypoint 通常使用 `#!/usr/bin/env node`。Bridge 不会把 `/usr/bin/env` 误当成 Node，而会继续解析真实 Node 可执行文件并冻结其身份。macOS LaunchAgent 的 PATH 比终端小；如果 Node 只在 `nvm`、`asdf` 等交互式 shell 初始化后可见，Probe 可能找不到它。应确保已构建 entrypoint 的 shebang 能在 Service 环境解析到受支持的真实 Node 安装，然后以 App Probe 结果为准。

不要读取或复制 Node 安装目录中的无关认证文件来解决 PATH 问题。

## 4. 安装依赖并构建 ACP Demo

在已经 checkout 固定 tag 的 DSH 源码根目录运行：

```bash
pnpm install --frozen-lockfile
pnpm run build
```

确认正确产物存在：

```bash
test -f packages/examples/acp-demo/lib/bin.js
```

Bridge 要登记的就是这个构建产物的绝对路径：

```text
<dsh-source>/packages/examples/acp-demo/lib/bin.js
```

### 不要选择这些对象

```text
dsh
pnpm dsh web
packages/examples/acp-demo/src/
packages/examples/acp-demo/src/bin.ts
apps/cli/
DSH Web UI
整个 deepseek-harness 文件夹
```

Bridge 实际执行语义是：

```text
<真实 Node> <dsh-source>/packages/examples/acp-demo/lib/bin.js \
  --config <Bridge 私有运行副本>/cordis.yml
```

不需要先启动 `pnpm dsh web`，也不需要保持终端或浏览器中的 DSH UI 打开。

## 5. 为什么 Bridge 需要完整源码树

虽然文件选择器只选择 `lib/bin.js`，Bridge 还会从它向上定位唯一 DSH 源根，并检查：

- `package.json` 中的名称、版本、Node engine 与 package manager；
- `pnpm-lock.yaml` 中固定 ACP SDK 版本；
- entrypoint 文件身份与 SHA；
- 真实 Node 解释器路径、版本与文件身份；
- ACP initialize/session 行为；
- Adapter revision。

因此不要把 `bin.js` 单独复制到其他文件夹。缺少原始 `package.json`、`pnpm-lock.yaml` 或 `node_modules` 会使 Probe/运行失败。DSH 更新后，即使路径相同，Bridge 也会要求重新复核，而不是静默信任替换后的文件。

## 6. 准备外部 Profile

运行时强制 `cordis.yml` 位于 DSH 源码树之外。出于凭据隔离和防止 Agent/Git 误读，建议 Profile 另外位于任务项目和 Codex Bridge 仓库之外：

- **必须**：DSH 源码树之外；
- **建议**：任务项目之外；
- **建议**：Codex Bridge 仓库之外；
- 只有当前本机用户可合理访问的位置。

推荐结构：

```text
<dsh-profile>/
├── cordis.yml
└── .env
```

`cordis.yml` 与 `.env` 必须在同一目录。Bridge 以该目录作为 Harness 工作目录，因此 DSH 可以自己加载旁边的 `.env`。Bridge 不打开、保存、摘要、日志记录或回传 `.env` 内容。

### 6.1 从 Bridge 随包模板复制 `cordis.yml`

优先使用与当前 Bridge 版本匹配的完整模板；最终是否兼容由 Profile 结构校验和 Probe 决定。

从源码工作区复制：

```bash
mkdir -p /path/to/dsh-profile

cp Packages/BridgeCore/Sources/BridgeDeepSeekHarnessACP/Resources/cordis.yml \
  /path/to/dsh-profile/cordis.yml
```

上面的相对路径需要在 Codex Bridge 仓库根目录执行。

从已安装 App 复制：

```bash
mkdir -p /path/to/dsh-profile

cp /Applications/CodexBridge.app/Contents/Resources/BridgeCore_BridgeDeepSeekHarnessACP.bundle/Contents/Resources/cordis.yml \
  /path/to/dsh-profile/cordis.yml
```

如果 App 不在 `/Applications`，从实际安装位置的相同 Bundle 相对路径复制。旧模板可能缺少当前能力或无法通过结构校验，因此应优先复制当前 App 的版本。

### 6.2 不要手工重建或精简模板

随包 `cordis.yml` 已包含 Bridge 当前验证过的组合，包括：

- workspace/sandbox 模式；
- 文件读取、搜索和编辑；
- shell/subprocess；
- Web Search 与 HTTP fetch；
- code runtime；
- subagent；
- workflow/todo；
- ACP 工具与 execution evidence；
- 私有状态和快照目录。

普通用户不应删除插件、改写 sandbox 结构或把模板改成另一种通用 DSH 配置。模型目录、默认模型、thinking/reasoning effort 是预期的可配置内容；兼容的尾部扩展也可能通过归一化结构校验，但任何改动都应重新 Probe，结构不兼容时会触发 `templateMismatch` 或 `needs_review`。

## 7. 创建 `.env` 并配置 DeepSeek API Key

DeepSeek API Key 可从 [DeepSeek Platform API Keys](https://platform.deepseek.com/api_keys) 创建。只把真实 Key 粘贴到本机 Profile 的 `.env`，不要放进 Bridge UI、项目 `.env`、聊天、截图、Issue 或 Git。

Codex Bridge 仓库提供示例：

```bash
cp Examples/DeepSeekHarnessProfile/.env.example \
  /path/to/dsh-profile/.env
```

也可以在外部 Profile 中按以下变量名创建：

```dotenv
DEEPSEEK_API_KEY=<在本机填写真实 Key>
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_SEARCH_BASE_URL=https://api.deepseek.com/anthropic/v1
```

设置文件权限时，可限制为当前用户读取：

```bash
chmod 600 /path/to/dsh-profile/.env
```

不要把 `/path/to/dsh-profile` 原样当作目录；请换成你实际创建的外部 Profile 绝对路径。

## 8. 正确理解两个 Base URL

### 8.1 主模型：`DEEPSEEK_BASE_URL`

该值是 DeepSeek-compatible Chat Completions 的**基础 URL**，不要带 `/chat/completions`。DSH 会自己追加请求路径。

```text
完整接口：https://gateway.example/v1/chat/completions
应填写：  DEEPSEEK_BASE_URL=https://gateway.example/v1
```

```text
完整接口：https://gateway.example/chat/completions
应填写：  DEEPSEEK_BASE_URL=https://gateway.example
```

当前 DSH 主模型适配器使用 Chat Completions 协议。把 URL 改成 `/v1/responses` 不会自动变成 Responses API。

### 8.2 Web Search：`DEEPSEEK_SEARCH_BASE_URL`

该值独立于主模型 URL，并且不要带 `/messages`。DSH 会追加：

```text
/messages
```

Search endpoint 必须同时满足：

1. 接受 Anthropic Messages-compatible 请求；
2. 支持原生 `web_search_20250305` server tool；
3. 接受当前模板使用的 `DEEPSEEK_API_KEY`。

“主模型能回答”“网关支持 `/messages`”或“认证成功”都不能单独证明 Web Search 可用。自定义网关若用不同的搜索凭据，而当前模板只配置 `DEEPSEEK_API_KEY`，需要先确认该 Key 对两个端点都有效；不要让 Bridge 读取或转换凭据来弥补网关配置差异。

## 9. 在 Codex Bridge 登记 DSH

1. 打开 `CodexBridge.app`。
2. 进入 `连接 → 本机 Agent 引擎连接`。
3. 点击“登记 Agent”。
4. 选择“DeepSeek Harness”。
5. 在“选择 DeepSeek Harness 可执行文件”中选择：

   ```text
   <dsh-source>/packages/examples/acp-demo/lib/bin.js
   ```

6. 点击“下一步”。
7. 在“选择 DeepSeek Harness cordis.yml”中选择：

   ```text
   <dsh-profile>/cordis.yml
   ```

8. 点击“登记并 Probe”。
9. 检查安装卡片显示的版本、protocol、Adapter revision 和状态。
10. 状态为“可用”后，打开“启用”。

登记成功不会自动启用。Probe 成功只证明本地安装、版本、协议和基础 ACP Session 可用；Probe/模型刷新使用禁网检查，不能证明你的 API Key、账号额度、主模型请求或 Web Search 已经真实成功。

## 10. 刷新模型和设置默认值

1. 先在 `工作台` 选择任务项目。
2. 打开 `设置 → DeepSeek Harness 执行默认偏好`。
3. 有多个 DSH 安装时，选择目标安装实例。
4. 点击“刷新模型列表”。
5. 选择 DSH 当前 ACP Session 返回的精确模型 ID。
6. 选择当前 DSH Profile 支持的 effort。模型 ID 来自 ACP 动态目录；effort 不是按模型由 ACP 单独广告。
7. 保存默认访问模式。

模型目录来自：

```text
session/new → configOptions
```

不是 OpenCode 模型目录，也不是 Bridge 根据 Provider 名称猜出的别名。effort 列表来自经过验证的 DSH Profile：当前随包 Profile 在 thinking 启用时支持 `off/low/high/max`，默认 `max`；thinking 关闭时只支持 `off`。没有显式模型覆盖时，Bridge 保留 DSH/Profile 的 current value 或已保存且仍有效的默认值；不应随便选目录第一项。

当前静态模型回退为 `deepseek-v4-pro`。真实模型优先使用当前 ACP 动态目录，effort 则继续使用已验证 Profile 的支持集合。

## 11. 权限、网络与工作区

DSH 支持：

- `read-only`
- `workspace-write`

项目硬策略始终优先。项目禁止写入时，任务只能收窄为只读。

- 只读任务可在共享项目中并行。
- 同一项目最多一个活动写任务；DSH 与其他 Provider/Direct 共享 workspace gate。
- DSH 使用 Profile 和 Provider 原生策略，Bridge 不再套外层 `sandbox-exec`。
- `network_access=true` 表示用户明确请求网络并通过项目准入，不是 Bridge 提供逐包网络隔离。

需要 Web Search、URL fetch 或外部 API 时，任务必须明确设置 `network_access=true`，并且项目网络策略必须允许或经本机批准。

## 12. 从 ChatGPT/Qwen 提交 DSH 任务

提交前先调用：

```text
list_projects
list_agents
```

确认 DSH 安装满足：

```json
{
  "provider_id": "deepseek-harness",
  "availability": "available",
  "enabled": true,
  "task_submission_enabled": true
}
```

当 Workbench 已选择正确项目和权限时，最小任务：

```json
{
  "provider_id": "deepseek-harness",
  "prompt": "检查当前项目结构并总结构建问题。",
  "network_access": false
}
```

需要 Web Search：

```json
{
  "provider_id": "deepseek-harness",
  "prompt": "结合官方资料核对当前依赖的兼容性，并给出来源。",
  "network_access": true
}
```

仅当用户明确要求覆盖模型或权限时，才增加：

```json
{
  "provider_id": "deepseek-harness",
  "installation_id": "<list_agents 返回的安装 ID>",
  "prompt": "完成指定任务。",
  "model_override": true,
  "execution_model": "<当前 DSH 模型目录中的精确 ID>",
  "execution_effort": "<当前 DSH Profile 支持的 effort>",
  "permission_mode": "workspace-write",
  "permission_mode_override": true,
  "network_access": false
}
```

规则：

- `installation_id` 通常可以省略，由 Bridge 选择已启用且可用的安装。
- DSH 当前只支持新建 Session，不要传历史 `thread_id`。
- 不要传 Codex Supervisor 字段。
- `skill_name` 只在用户明确选择已发现的 Bridge Skill 时使用。
- 模型 ID 和 effort 不能从 Codex/OpenCode/Antigravity 复制。

## 13. 审批、结果、继续与中断

### 13.1 远程启动

ChatGPT/Qwen 提交后通常先得到：

```text
awaiting_local_approval
```

打开 Bridge 工作台，核对项目、DSH 安装、权限、网络意图和 prompt 后点击“批准启动”。设置中的“自动批准远程 Agent 启动请求”默认关闭；开启后也只批准启动，不批准 DSH 后续的 `session/request_permission`。

### 13.2 读取结果

按 `get_task.wait_policy` 轮询 `get_task`。不要因为 DSH 暂时没有文本输出或 `updated_at` 未变化就判断失败。终态的 `next_action=read_final_report` 只是提示字符串，不是另一个 MCP 工具；进入终态后，从同一任务快照读取：

- `result_summary`
- `failure_code`
- `changed_files`
- `recent_activity`
- `provider_session_id`
- `provider_run_id`
- `execution_model`
- `execution_effort`
- `permission_mode`

### 13.3 继续和中断

- 普通 `steer_task` 会把补充指令排队，在当前 prompt 完成后作为下一次 prompt 发送。
- DSH 还支持“中断当前轮后继续”，先中断当前执行，再在同一当前 Session 中发送后续 prompt。
- 这两者都不是 Codex 的 in-flight steer。
- 历史终态 DSH 任务当前不能通过 `provider_session_id` 恢复；新任务会创建新 Session。

任务控制使用当前 `provider_run_id` 作为 `expected_turn_id`，避免对已经切换的运行发送过期控制命令。

## 14. `available`、`needs_review` 与 `unavailable`

### `available`

表示当前受信任本地安装、固定版本、协议和基础 Session Probe 通过。它不证明 API Key 或真实网络任务成功。

### `needs_review`

常见原因：

- `bin.js` 被重新构建或替换；
- DSH 源码切换 tag；
- `package.json` 或 `pnpm-lock.yaml` 变化；
- Node 解释器路径/身份变化；
- Adapter revision 变化；
- `cordis.yml` 模板结构变化。

处理：

1. 核对路径仍是固定 tag 构建出的 `packages/examples/acp-demo/lib/bin.js`。
2. 核对 Node 与 pnpm 版本。
3. 从当前 Bridge 随包模板重新复制 `cordis.yml`，保留本机 `.env` 不变。
4. 确认替换来源可信后点击“接受替换并 Probe”。
5. Probe 成功后再启用。

### `unavailable`

表示当前不能执行。查看安装卡片或 `list_agents.unavailable_reason`，优先检查路径、版本、Node、manifest、lock、模板和 ACP 握手。

## 15. 常见故障

| 现象 | 优先检查 |
| --- | --- |
| 选择文件后提示 artifact 无效 | 是否选择固定 tag 构建后的 `packages/examples/acp-demo/lib/bin.js`；是否保留完整源码树 |
| Node 不支持 | 使用 Node 22.19.0+ 的 22.x 或 Node 24+；不要使用 Node 23 |
| App 找不到 Node | Node 是否只存在于交互式 shell PATH；Service 能否解析 shebang 指向的真实 Node |
| 找不到 manifest/lock | 是否把 `bin.js` 单独复制走；源根是否仍有 `package.json` 和 `pnpm-lock.yaml` |
| Profile 位置被拒绝 | 运行时强制把 `cordis.yml`/`.env` 移出 DSH 源码树；同时建议使用任务项目之外的专用目录 |
| `templateMismatch` | 从当前 Bridge 随包模板重新复制，不要手工删插件或改 sandbox 结构 |
| Probe 成功但 API 认证失败 | `.env` 是否与注册的 `cordis.yml` 同目录；Key 是否有效、有额度；主 Base URL 是否正确 |
| 主模型 404 | `DEEPSEEK_BASE_URL` 是否错误包含 `/chat/completions`，或网关是否实际支持该协议 |
| 主模型可用但 Web Search 认证失败 | 检查独立 `DEEPSEEK_SEARCH_BASE_URL` 与该 endpoint 对当前 Key 的接受情况 |
| 有 `/messages` 但没有搜索结果 | endpoint 是否明确支持 `web_search_20250305`，不能只看“Anthropic compatible”标签 |
| 模型列表为空 | 选择正确 Workbench 项目和 DSH 安装后刷新；检查 ACP `configOptions` |
| 模型/effort 不可用 | 模型使用当前 ACP Session 返回的精确值；effort 使用当前 Profile 支持集合，不要使用其他 Provider 的别名 |
| 写入被拒绝 | Workbench/任务是否只读；项目硬策略是否禁止写入；同项目是否已有写任务 |
| 网络工具被拒绝 | 任务是否明确 `network_access=true`；项目网络策略和 DSH 原生权限是否允许 |
| 任务停在等待状态 | 在工作台批准远程启动或处理 DSH 执行期 permission |
| 误以为要开启 Web UI | Bridge 直接运行 ACP stdio，不需要 `pnpm dsh web` |

## 16. 安全与验收边界

- 不向 Bridge、ChatGPT、Issue 或日志粘贴 `.env` 或真实 Key。
- 不把 Profile 放进任务项目，避免 Agent 或 Git 意外读取/提交。
- Bridge 日志会尝试脱敏常见 bearer、API key、token、secret 和 cookie，但报告问题前仍应人工检查日志片段。
- Probe 成功不等于 DeepSeek API、Web Search、外部网关、账号额度、Provider 工具审批或真实文件写入已验收。
- 最终验收必须用你自己的账号，在明确授权的测试项目中分别验证主模型、Web Search、只读、写任务和 permission 回传。

## 17. 参考

- [DeepSeek Harness 官方仓库](https://github.com/deepseek-ai/deepseek-harness)
- [DeepSeek API 文档](https://api-docs.deepseek.com/)
- [DeepSeek API Keys](https://platform.deepseek.com/api_keys)
- [Codex Bridge 详细使用指南](./USER_GUIDE.md)
- [ChatGPT Developer Mode 接入指南](./CHATGPT_DEVELOPER_MODE.md)
