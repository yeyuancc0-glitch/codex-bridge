# Codex Bridge

<p align="center">
  <b>简体中文</b> | <a href="./README_en.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-blue?style=flat-square&logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-6.0%20Strict-orange?style=flat-square&logo=swift" alt="Swift 6">
  <img src="https://img.shields.io/badge/Protocol-MCP%20Gateway-green?style=flat-square" alt="MCP">
  <img src="https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square" alt="License">
</p>

**Codex Bridge** 是一个面向个人自托管场景的原生 macOS App 与后台 Service。它把 ChatGPT 网页版、Qwen Studio 和本机工作台连接到已授权的本地项目，并在同一套任务、审批、对话和持久化系统中运行 Codex、OpenCode、DeepSeek Harness 与 Antigravity。

Bridge 不依赖开发者自建的云端中转、账号系统或远程数据库。通过 ChatGPT、模型 API 或 Provider 执行任务时，请求内容仍会发送给你主动选择和配置的对应服务；“本地优先”不等于所有数据永远不离开 Mac。

## 当前能力

| 层级 | 当前实现 |
| --- | --- |
| ChatGPT 网页版 | OpenAI Secure MCP Tunnel；Tunnel Helper 随正式 App 打包并由 Service 管理 |
| Qwen Studio | 本机回环 Streamable HTTP `/mcp`；App 一键复制带认证 Header 的 JSON |
| Codex | 默认 Provider；`codex app-server --stdio`、Thread/Turn、实时 steer、interrupt、审批与 Supervisor |
| OpenCode | ACP stdio；Plan/Build、动态模型与 effort、permission 回传、同 Session 排队继续 |
| DeepSeek Harness | 固定版本 ACP 适配；外部 `cordis.yml`、模型/effort、Web/工具/子代理、执行证据与逐次本机审批 |
| Antigravity | `agy` CLI stream-json；Plan/Accept Edits、原生 sandbox、CLI 权限规则、会话继续与 queued steer |
| Direct Workspace | 受控读写、revision 校验、Patch、结构化命令、进程会话和本地 Git 提交 |
| Skills | 安全发现 `SKILL.md`，只执行显式声明的 Action |

外部 Agent 必须由用户明确登记、Probe、启用并在任务中显式选择；没有 `provider_id` 的 `submit_task` 始终使用 Codex。

## 架构

```text
ChatGPT Web                         Qwen Studio
    │ OpenAI Secure MCP Tunnel          │ localhost /mcp
    └──────────────────┬────────────────┘
                       ▼
              CodexBridgeService
              ├─ MCP / XPC 应用服务
              ├─ 单一 service.sqlite
              ├─ 项目策略与本机审批
              ├─ Provider 任务协调
              ├─ Direct Workspace
              └─ Tunnel / Skill 生命周期
                       │
        ┌──────────────┼───────────────┬────────────────┐
        ▼              ▼               ▼                ▼
 Codex app-server  OpenCode ACP  DeepSeek Harness ACP  agy CLI
        │
        └─ Supervisor（当前仅 Codex）

CodexBridge.app ── XPC ──► CodexBridgeService
   项目 / 工作台 / 连接 / 设置 / 审批 / 状态
```

生产 Service 只使用一个 SQLite 数据库保存项目、设置、任务、消息和展示事件。App 负责配置、查看和本机授权，不持有 Provider、MCP、Tunnel 或 Supervisor 的进程生命周期。

## 快速开始

完整首次配置请直接阅读 [详细使用指南](./docs/USER_GUIDE.md)。以下步骤用于快速建立正确顺序。

### 1. 安装并启动

- 运行环境：macOS 14.0 或更高版本，支持 Apple Silicon 与 Intel。
- 发布包按 `arm64` 与 `x86_64` 分开提供；请选择与 Mac 一致的架构。
- 首次打开后，如果 App 显示“等待 macOS 登录项批准”，点击“打开系统设置”并允许 Codex Bridge 后台 Service，然后回到 App 刷新状态。
- 关闭窗口不会停止 Service。`设置 → 后台运行与远程 Agent 授权` 中的“退出 App 后保持后台服务运行”决定按 ⌘Q 后是否继续，默认开启。

从源码构建：

```bash
git clone https://github.com/yeyuancc0-glitch/codex-bridge.git
cd codex-bridge

Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj \
  -scheme CodexBridge \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode \
  build CODE_SIGNING_ALLOWED=NO
```

普通 Debug 构建可能没有打包 OpenAI `tunnel-client`，因此可以使用本地 MCP，但未必能连接 ChatGPT Secure Tunnel。ChatGPT 接入请使用“连接”页面显示 Helper 就绪的正式构建。

### 2. 添加项目并设置硬权限

1. 打开 `项目 → 添加`，选择允许 Bridge 访问的项目根目录。
2. 在项目的“访问与执行权限”中配置读取、写入与网络策略。
3. 需要 Direct 命令时，再配置命令模式、允许命令和工作目录。

Bridge 只接受已登记项目。项目硬策略优先于 Workbench 默认和单任务请求；项目禁止写入时，任何 Provider 的写模式都会被收窄。

### 3. 选择远程任务默认项目与模式

打开 `工作台`：

1. 选择 ChatGPT/Qwen 新任务应使用的项目。
2. 在“GPT/Qwen 新任务”中选择 `Read Only` 或 `Write`。

远程请求省略 `project_id` 时使用这里选中的项目。若显式传入 `project_id`，它必须来自 MCP `list_projects`，不能填写项目显示名。远程客户端通常应省略权限覆盖字段，使用 Workbench 的统一默认值。

### 4. 配置执行 Provider

- **Codex**：默认 Provider，不在“本机 Agent 引擎连接”中登记。请先在官方 Codex/ChatGPT 环境完成登录，再到 `设置 → Codex 执行默认偏好` 选择模型、effort、访问权限和 Fast 模式。Bridge 不读取 Codex 认证文件。
- **OpenCode**：`连接 → 本机 Agent 引擎连接 → 登记 Agent → OpenCode`，选择真实 `opencode` 可执行文件并 Probe。详见 [OpenCode 连接指南](./docs/OPENCODE_CONNECTION_GUIDE.md)。
- **DeepSeek Harness**：登记官方 `dsh-v0.1.1-rc.2` 构建出的 `packages/examples/acp-demo/lib/bin.js`，再选择 DSH 源码树之外的 `cordis.yml`；为隔离凭据，建议 Profile 也位于任务项目和 Bridge 仓库之外。`.env` 与 `cordis.yml` 同目录，由 Harness 自己读取。详见 [DeepSeek Harness 接入指南](./docs/DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)。
- **Antigravity**：先用 `command -v agy` 找到真实 CLI，在目标项目中交互登录，并通过 `/settings`、`/permissions` 配置 headless 所需的命令、URL 与 MCP 规则；不要登记 Desktop App。详见 [Antigravity / AGY 连接与权限指南](./docs/ANTIGRAVITY_CONNECTION_GUIDE.md)。

外部 Provider 登记成功后还要打开“启用”，然后到 `设置` 中刷新该 Provider 的模型目录并保存默认模型/effort。模型 ID 以当前 Provider 实际返回值为准，不要跨 Provider 猜别名。

### 外部 Provider 权限要点

- ChatGPT/Qwen 的 `Read Only / Write` 由工作台决定；Provider 设置页中的访问权限只是后备默认。
- DSH 保持 `approval.policy: ask`，运行中在工作台对每个 `session/request_permission` 选择“仅本次允许”或拒绝。`full-access` 和自动批准任务启动都不会跳过该步骤。
- AGY 正常使用前，必须在交互式 `agy` 的 `/settings` 中确认 **Tool Permission = `proceed-in-sandbox`**（沙箱内终端命令自动执行），再用 Project 作用域的 `/permissions` 添加窄 allow 规则。Bridge 已强制传入 `--sandbox`。
- 项目网络选择器不是外部 Provider 的网络包级防火墙；联网任务需显式 `network_access=true`，真实网络仍由 AGY/DSH 原生配置和工具权限负责。

### 5. 连接 Chat 客户端

#### ChatGPT 网页版

1. 在 [OpenAI Platform Tunnels](https://platform.openai.com/settings/organization/tunnels) 创建或取得 Tunnel。
2. 在 [OpenAI Platform API Keys](https://platform.openai.com/settings/organization/api-keys) 创建 Restricted Runtime API Key，并只授予 Tunnel `Read` 与 `Use`。
3. 在 Bridge 的 `连接 → 远程 AI 客户端 (OpenAI Secure Tunnel)` 填入 `Tunnel ID` 和 `Runtime API Key`，点击“保存并启动连接”。Runtime Key 只保存在 macOS Keychain。
4. 按当前 OpenAI 官方页面，在 ChatGPT 的 Apps/Developer Mode 中创建 MCP App；常见流程是选择 **Tunnel**、选择或粘贴同一个 Tunnel ID、扫描工具并创建连接，实际入口以当前账号与 Workspace 页面为准。

Runtime API Key 只填在 Bridge，不填进 ChatGPT 对话或 MCP App；ChatGPT Tunnel 配置也不填写 `127.0.0.1`、`/mcp` 或 Bridge 为 ChatGPT profile 单独生成的本地 Header Secret。账号权限、当前页面入口和完整步骤见 [ChatGPT Developer Mode 接入指南](./docs/CHATGPT_DEVELOPER_MODE.md)。

#### Qwen Studio

1. 打开 `连接 → 本地 MCP 客户端通道`。
2. 打开“启用 Qwen Studio”，选择“只读”或“完整”。
3. 点击“复制 Qwen JSON 配置”，在 Qwen Studio 的 MCP 页面选择使用 JSON 添加。

JSON 中包含本地认证 Header，不要提交到 Git、公开文档或聊天群。重新生成凭证后，旧 JSON 会立即失效，需要重新复制。

## 任务、审批与结果

远程 Provider 任务的正常状态流：

```text
submit_task
    ↓
awaiting_local_approval（默认）
    ↓ 本机“批准启动”
starting → running ↔ waiting_for_codex_approval
               ↓
    completed / failed / interrupted

unknown：失去原运行绑定后的非终态，需要本机复核
```

- “自动批准远程 Agent 启动请求”默认关闭。开启后只自动批准远程 Provider 的启动，不会连带批准 Provider 工具或 Direct 操作。
- 同一项目最多一个活动的 `workspace-write` 任务；只读任务可并行。
- `get_task` 的终态是任务成败权威。按其 `wait_policy` 等待；暂时没有活动或更新时间不变不代表失败。
- 终态继续从 `get_task` 读取 `result_summary`、`failure_code`、`changed_files` 和 Provider 绑定。当前 MCP 工具目录没有 `get_final_report`；`wait_policy.next_action=read_final_report` 只是提示字符串，不是可调用工具。
- OpenCode 与 Antigravity 可以在严格匹配的历史 Session 上继续；DeepSeek Harness 当前为每个任务创建新 Session，不支持历史 Session 续接。外部 Provider 的 steer 通常是当前 prompt 完成后的排队 prompt，不等同于 Codex 的 in-flight steer。

## 权限与隐私边界

| 边界 | 行为 |
| --- | --- |
| 已登记项目 | MCP 只接受不透明项目 ID；文件路径必须位于项目根内且通过身份校验 |
| 敏感文件 | 拒绝 `.env*`、私钥、认证文件、浏览器数据等敏感路径 |
| 写入并发 | 同一项目只有一个活动写任务；Direct 与 Provider 共享工作区门禁 |
| Provider 授权 | 远程启动、Provider 执行期 permission 与 Direct 操作是不同审批层级 |
| 凭据 | Tunnel Runtime Key 与按客户端 profile 分离的本地 MCP Secret 存入 Keychain；Bridge 不读取 Provider 的账号凭据或 DSH `.env` |
| 网络 | Codex/Direct 受项目策略约束；外部 Provider 记录明确任务意图并使用原生网络策略，项目选择器不是逐包防火墙 |
| Git | `direct_git_commit` 只创建受控本地提交，不允许 push、amend、reset 或历史改写 |

## 项目结构

```text
App/                                  macOS App 入口
Packages/BridgeCore/Sources/
  BridgeServiceCore/                  service.sqlite、项目、设置、任务、消息
  BridgeServiceApplication/           MCP/XPC 共用业务门面与权限边界
  BridgeCodexRPC/                      codex app-server 协议适配
  BridgeCodexService/                  Codex 执行、Supervisor、协调与对话
  BridgeAgentCore/                     外部 Provider、安装、能力与事件契约
  BridgeACP/                           ACP 共用 transport 与 request broker
  BridgeOpenCodeACP/                   OpenCode ACP 适配
  BridgeDeepSeekHarnessACP/            DeepSeek Harness ACP 与随包 Profile
  BridgeAntigravityCLI/                Antigravity CLI 适配
  BridgeMCP/                           唯一 MCP 控制面
  BridgeDirectCommand/                 Direct 命令、Git、进程与审批
  BridgeSkills/                        Skill 发现与显式 Action
  BridgeTunnel/                        Secure MCP Tunnel 生命周期与健康检查
  BridgeIPC/                           版本化 XPC DTO 与 Client
  BridgeServiceHost/                   后台 Service 组合根
  BridgeServiceAppShell/               工作台、项目、连接、设置和本机审批 UI
Scripts/                              构建、检查、打包与发布脚本
docs/                                 用户与开发文档
```

## 开发与验证

```bash
Scripts/with-xcode.sh swift build --package-path Packages/BridgeCore
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive \
  Packages/BridgeCore/Sources App Service
Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj \
  -scheme CodexBridge \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode \
  build CODE_SIGNING_ALLOWED=NO
```

Xcode/Swift 命令统一经 `Scripts/with-xcode.sh` 选择工具链。App 打包、安装和签名只能证明本地产物状态；真实 ChatGPT、Qwen 与各 Provider 登录、联网、工具和审批体验仍需要使用对应账号手动验收。

## 文档

- [详细使用指南](./docs/USER_GUIDE.md)
- [ChatGPT Developer Mode 接入指南](./docs/CHATGPT_DEVELOPER_MODE.md)
- [OpenCode 连接指南](./docs/OPENCODE_CONNECTION_GUIDE.md)
- [DeepSeek Harness 接入指南](./docs/DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)
- [Antigravity / AGY 连接与权限指南](./docs/ANTIGRAVITY_CONNECTION_GUIDE.md)
- [系统与环境兼容性矩阵](./docs/COMPATIBILITY.md)
- [Secure Tunnel Helper 技术说明](./docs/TUNNEL_CLIENT_INTEGRATION.md)
- [构建、签名与发布流程](./docs/RELEASE.md)
- [依赖版本与许可](./docs/DEPENDENCIES.md)

## 许可与安全报告

项目基于 [Apache License 2.0](./LICENSE) 开源，第三方声明见 [NOTICE](./NOTICE)。隐私与漏洞报告方式见 [PRIVACY.md](./PRIVACY.md) 与 [SECURITY.md](./SECURITY.md)。请勿在 Issue、日志或截图中公开 API Key、Token、Cookie、`.env` 或敏感项目源码。
