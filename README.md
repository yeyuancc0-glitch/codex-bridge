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

**Codex Bridge** 是一个**零云端中转、个人自托管、纯本地优先**的 macOS 桥接中枢与 MCP 网关。

它致力于**全面打通 Chat 对话端与本地工程环境及 Coding Agent 引擎**：
- 🌟 **多 Chat 端原生接入**：支持 **ChatGPT 网页版**、**通义千问桌面版 (Qwen Studio)** 等现代 AI 客户端；
- 📂 **本地项目直读直写**：赋予 Chat 客户端直接检索代码树、读取项目源码、原子编辑、应用 Unified Diff Patch 与受控 Git 提交的能力；
- 🤖 **多 Agent 统一调度**：无缝桥接本地 **Codex** 与 **OpenCode** 执行引擎，支持深度多轮与自主编码；
- 🎯 **安全 Skill 扩展系统**：基于标准 `SKILL.md` 规范与 Action 契约，支持 `sandbox-exec` 沙盒隔离执行，无缝扩展专用脚本、全网调研与自动化能力；
- 🛡️ **本地唯一授权（Local-Only Approval）**：任何高危文件写入、命令执行与 Git 提交，均由 Mac 桌面原生弹窗由用户手动授权，代码与凭据全程不出本机。

---

## 🌟 核心能力矩阵

```text
  【Chat 端接入】                                           【能力与执行引擎】
┌──────────────────┐                                     ┌──────────────────┐
│  ChatGPT 网页版   │ ──(OpenAI Secure Tunnel 穿透)──┐   ├─► 本机 Codex 引擎 │ (app-server + 独立监督)
└──────────────────┘                                │   ├──────────────────┤
┌──────────────────┐                                ├──►│本机 OpenCode 引擎│ (ACP 协议 + Plan/Build)
│ Qwen Studio 桌面版│ ──(本地回环 HTTP /mcp 端点)───┘   ├──────────────────┤
└──────────────────┘                                    ├─► 本地项目直接读写│ (检索/编辑/Patch/受控 Git)
                                                        ├──────────────────┤
                                                        └─► Skill 扩展系统  │ (Action 契约/沙盒隔离)
```

- 🌐 **多 Chat 端原生适配**：
  - **ChatGPT 网页版**：通过 OpenAI 官方 Secure MCP Tunnel 端到端安全穿透，在网页端直接调度本地工程环境。
  - **Qwen Studio (通义千问桌面版)**：通过稳定的本地回环 Streamable HTTP `/mcp` 端点极速直连，一键复制配置即用。
- 📂 **本地项目原生读写与版本控制**：
  - **目录与源码检索**：Chat 端可直接获取受限工程目录树、全文读取文件内容、检查上下文。
  - **精确 Patch 与原子写入**：支持 Bridge 标准语法及 Unified Diff 标准补丁，写入受 Mac 本地弹窗二次确认保护。
  - **受控 Git 提交**：使用独立临时 index 隔离变更，自动扫描并拦截私钥凭据，严禁破坏性 `push` 或重写历史。
- 🎯 **安全 Skill 扩展生态**：
  - **标准规范**：兼容 `SKILL.md` 规范与 YAML Frontmatter，支持复杂 Action 契约与自动发现。
  - **沙盒隔离**：支持 `sandbox-exec` 禁网环境隔离执行，未声明网络能力的脚本默认限制网络外连。
- 🧩 **多 Agent 引擎统一桥接**：
  - **Codex 深度引擎**：基于官方 `codex app-server` stdio 协议，支持多轮对话、子代理协作、独立 Supervisor 监督与打字机实时流。
  - **OpenCode ACP 引擎**：基于 Agent Client Protocol (ACP) stdio 协议，支持原生 Plan / Build 模式切换与动态模型/推理强度（effort）自适应。
- 🔒 **纯本地自托管（Zero-Cloud）**：无任何第三方云服务器中转、无开发者数据库、无账号系统，代码与凭据全程不出本机。
- 🖥️ **原生 macOS 架构（SwiftUI + AppKit + LaunchAgent）**：后台独立常驻守护服务，退出 App 界面不中断任务；内置工作台支持打字机实时流式对话、思考链折叠与工具进度卡片。

---

## 🏗️ 架构拓扑

```text
┌────────────────────────┐      ┌────────────────────────┐
│      ChatGPT 网页版     │      │   Qwen Studio 桌面版   │
│  (OpenAI Secure Tunnel)│      │  (本地 HTTP /mcp 端点)  │
└───────────┬────────────┘      └───────────┬────────────┘
            │                               │
            └───────────────┬───────────────┘
                            ▼
            ┌──────────────────────────────────────────────┐
            │        CodexBridgeService (后台常驻守护)      │
            │  ├─ 统一 MCP 网关 (ChatGPT / Qwen Client)     │
            │  ├─ Agent 调度中心 (Codex / OpenCode Runner)  │
            │  ├─ Direct 项目读写与 Git 管理 (Direct Tools) │
            │  ├─ Skill 沙盒执行引擎 (BridgeSkills)        │
            │  ├─ 单 SQLite 存储 (任务、项目、设置)          │
            │  └─ 本机安全与审批中心 (Local Approval Center)│
            └──────┬──────────────┬──────────────┬─────────┘
                   │              │              │
     Mach XPC 通信 │   stdio RPC  │    stdio ACP │  posix_spawn / sandbox-exec
                   ▼              ▼              ▼         ▼
      ┌──────────────────┐ ┌────────────┐ ┌────────────┐ ┌───────────────────┐
      │ CodexBridge.app  │ │ 本机 Codex │ │本机 OpenCode│ │ Direct 项目读写 / │
      │(原生 macOS 工作台)│ │ (深度引擎) │ │ (ACP 引擎)  │ │ Skill 扩展执行    │
      └──────────────────┘ └────────────┘ └────────────┘ └───────────────────┘
```

---

## 🚀 四大核心工作流

### 1. Codex 深度编码工作流（主推模式）
```text
ChatGPT / Qwen ──[submit_task]──► CodexBridgeService ──► 本地 Codex 引擎 (app-server)
      ▲                                                         │
      │                                                         ▼
  [get_task] 实时获取进度与报告   ◄──── 打字机流式同步 / 独立 Supervisor 监督
```
- **适用场景**：大型工程开发、多步复杂重构、端到端测试与环境排错。
- **特性**：自动绑定 Codex Thread，支持思考链折叠展示、工具执行进度可视化，后台异步执行，退出 App 任务不中断。

### 2. OpenCode ACP 编码工作流
```text
ChatGPT / Qwen / Bridge 工作台 ──[provider_id=opencode]──► 本机审批中心
                                                         │
                                                         ▼
                                         OpenCode ACP (Plan / Build)
```
- **适用场景**：多模型对比评估、基于 ACP 协议的标准 Agent 执行、灵活切换 Plan（只读规划）与 Build（写操作）模式。
- **特性**：模型目录从 ACP `session/new.configOptions` 动态获取，支持原生推理强度（effort）自适应调节。

### 3. Direct 项目直读直写与受控 Git 工作流
```text
ChatGPT / Qwen ──[direct_write_file]──► Mac 桌面审批弹窗 (Payload Digest 签名校验)
                                                  │
                                         [用户点击 允许 / 拒绝]
                                                  │
                                                  ▼
                                        原子写入本地工作区文件
```
- **适用场景**：快速修改配置文件、应用小型 Patch、查看工程目录、执行受控 Git 提交与安全只读命令。
- **特性**：单次有效签名凭据、防刷冷却机制、支持受控 `direct_git_commit`（隔离临时 index，敏感文件自动防泄漏）。

### 4. Skill 自动化与沙盒扩展工作流
```text
ChatGPT / Qwen ──[run_skill_action]──► 沙盒隔离检查 (sandbox-exec 禁网 / 权限)
                                                │
                                       [执行专项 Action 脚本]
                                                │
                                                ▼
                                      返回结构化执行收据与产物
```
- **适用场景**：执行项目内专用辅助脚本、自动化数据处理、网络信息收集与专业平台调研。
- **特性**：自动解析 `SKILL.md`，精确暴露 Action 契约，支持动态超时计算与沙盒隔离。

---

## 🛠️ 快速开始

### 1. 环境准备
- **操作系统**：macOS 14.0 (Sonoma) 或更高版本（支持 Apple Silicon 与 Intel）。
- **Agent 环境**：
  - **Codex**：本地已安装并登录 **Codex 桌面端**（或系统 PATH 具备可执行的 `codex` 命令）。
  - **OpenCode（可选）**：本地已安装 **OpenCode** 并具备可执行命令。
- **编译工具**：Xcode 16+ / Swift 6.0 工具链。

### 2. 构建与启动
```bash
# 克隆仓库
git clone https://github.com/yeyuancc0-glitch/codex-bridge.git
cd codex-bridge

# 编译并在本机运行
Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj \
  -scheme CodexBridge \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode \
  build CODE_SIGNING_ALLOWED=NO
```

启动 `CodexBridge.app` 后，应用会自动注册并启动内置的后台常驻服务 `CodexBridgeService`。

### 3. 注册本地工程与 Skill
在 App 中点击 **添加项目**，选择你允许 AI 访问的本地工程目录。Bridge 将严格锁定该目录的规范路径、设备 ID 与 Inode，防止符号链接逃逸，并自动识别项目内的 Skill 目录。

### 4. 配置 Agent 执行端
- **Codex 引擎**：检测到本地 `codex` 命令后默认开箱即用。
- **OpenCode 引擎**：在 Bridge 的“设置 → 本机 Agent Provider”中登记 OpenCode 可执行文件路径，Probe 检测为“可用”后点击启用。

### 5. 连接你的 Chat 客户端

#### 方式 A：连接 ChatGPT 网页版
1. 在 Bridge App 的“连接”页面选择 **Secure MCP Tunnel**，填入你的 OpenAI `Tunnel ID` 与 `Runtime Key`（密钥安全存入系统 Keychain）。
2. 打开 ChatGPT 网页端 → **Settings** → **Connected apps / Developer Mode** → **Add New Server**。
3. 选择 **OpenAI Secure Tunnel**，填入相同的 `Tunnel ID`，路径填写 `/mcp`。
4. 详细接入指南与 Prompt 示范请查阅：[👉 ChatGPT Developer Mode 详细接入手册](./docs/CHATGPT_DEVELOPER_MODE.md)。

#### 方式 B：连接 Qwen Studio (通义千问桌面版)
1. 在 Bridge App 的“连接”页面开启 **Qwen Studio 支持**。
2. 点击 **复制 MCP 配置 JSON**。
3. 打开 Qwen Studio 设置 → **MCP 服务配置**，粘贴配置即可直接开始对话！

---

## 🛡️ 安全与权限边界

| 安全防线 | 实现机制 |
| :--- | :--- |
| **本地唯一审批** | 外部 AI、Supervisor 均无权代替用户授权，高危操作必须在 Mac 桌面弹窗中人工确认。 |
| **工作区严格封闭** | 仅允许访问用户显式注册的项目目录，严禁访问系统敏感目录（如 `~/.ssh`、`.env*`、`/etc`）。 |
| **并发写锁互斥** | 同一项目同一时间仅允许一个活跃写任务（`project_busy` 互斥保护），彻底消除并发写冲突。 |
| **受控 Git 提交** | `direct_git_commit` 使用独立临时 index 隔离提交，自动拦截私钥敏感文件，严禁破坏性 `push` 或历史改写。 |
| **Skill 沙盒隔离** | 支持 Action 契约与 `sandbox-exec` 禁网环境隔离，未声明网络的脚本默认受限。 |
| **零凭据外泄** | 严禁读取、存储或上传 Codex `auth.json`、系统 Token 或浏览器 Cookie。 |

---

## 📂 项目结构导览

```text
App/                              macOS 原生客户端 (SwiftUI + AppKit)
CodexBridge.xcodeproj/            Xcode 组合工程 (App + 后台 LaunchAgent Target)
Packages/BridgeCore/
  Sources/BridgeServiceCore/      单 SQLite 数据层 (项目、任务、设置、事件)
  Sources/BridgeAgentCore/        Provider、安装、能力与执行契约
  Sources/BridgeOpenCodeACP/      OpenCode ACP stdio 适配、模型目录与事件归一化
  Sources/BridgeCodexRPC/         Codex app-server 协议适配器与 stdio 通信
  Sources/BridgeCodexService/     ExecutionManager、Supervisor、协调器与实时对话流
  Sources/BridgeServiceApplication/ MCP 与 XPC 共用的轻量业务服务层
  Sources/BridgeMCP/              受限 MCP 网关 (ChatGPT 与 Qwen Studio Profile)
  Sources/BridgeIPC/              版本化、高安全 XPC 进程间通信 Hub
  Sources/BridgeServiceHost/      后台 Service 组合根与生命周期管理
  Sources/BridgeServiceAppShell/  纯 UI 控制台：工作台、项目管理、审批弹窗
  Sources/BridgeDirectCommand/    Direct 进程管理、受控 Git 与命令安全策略
  Sources/BridgeSkills/           Skill 发现、YAML Frontmatter 解析与沙盒隔离
  Sources/BridgeTunnel/           Secure MCP Tunnel 进程管理与健康探测
  Sources/BridgeSecurity/         路径规范化、Device/Inode 校验与敏感信息拦截
Scripts/                          构建、代码检查、测试与 Tunnel 校验脚本
docs/                             详细技术规范与开发者接入手册
```

---

## 🧪 开发与测试基线

本项目遵循严格的质量与工程标准：

```bash
# 运行全部 Package 单元测试与集成测试
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore

# 运行严格 Swift-Format 代码规范检查
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive \
  Packages/BridgeCore/Sources Packages/BridgeCore/Tests App

# 运行官方 MCP Inspector 验收门禁
Scripts/verify-mcp-inspector.sh

# 运行 Tunnel Helper 兼容性检查
Scripts/test-tunnel-helper-config.sh
```

- **当前验证基准**：Swift 6 严格并发检查、完整 Package 测试、Universal 2 构建、MCP Inspector 2.1.0 与官方 tunnel-client 门禁均以本次 Release CI 和发布记录为准。

---

## 📚 详细文档

- [ChatGPT Developer Mode 接入指南](./docs/CHATGPT_DEVELOPER_MODE.md)
- [OpenCode 连接指南](./docs/OPENCODE_CONNECTION_GUIDE.md)
- [系统与环境兼容性矩阵](./docs/COMPATIBILITY.md)
- [依赖版本与开源许可证明](./docs/DEPENDENCIES.md)
- [Secure Tunnel Helper 对接技术规范](./docs/TUNNEL_CLIENT_INTEGRATION.md)
- [构建、签名与发布流程](./docs/RELEASE.md)

---

## 📄 开源协议与隐私

- **开源协议**：本项目基于 [Apache License 2.0](./LICENSE) 开源。第三方依赖版权声明参见 [NOTICE](./NOTICE)。
- **隐私与安全策略**：详情参见 [PRIVACY.md](./PRIVACY.md) 与 [SECURITY.md](./SECURITY.md)。请勿在 Issue 或讨论中公开私钥、Token 或敏感项目源码。
