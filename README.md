# Codex Bridge

<p align="center">
  <b>简体中文</b> | <a href="./README_en.md">English</a>
</p>

Codex Bridge 是一个**零开发者云端服务器、个人自托管**的 macOS 本机桥接工具，将 **ChatGPT 网页版**、**通义千问桌面版 (Qwen Studio)** 以及各类 MCP 客户端直接连接到你本地的 **Codex** 执行环境。

MCP 客户端通过协议安全读取用户显式注册的本地项目、绑定 Codex 会话 Thread、提交任务并与本地环境交互。原生 macOS SwiftUI/AppKit 应用程序提供项目管理、配置、打字机式流式实时对话展示以及本机审批控制；长期运行的后端则作为独立的用户后台服务 (`CodexBridgeService`) 稳定运行。

> **当前开发状态**：V1 后台 Service 架构已完整实现并经过全面验证。`CodexBridgeService` 作为随 App 打包的 LaunchAgent 后台进程运行，持有 MCP 网关、Secure Tunnel、回环 Streamable HTTP `/mcp` 端点、Codex 执行、独立 Supervisor 监督以及单 SQLite 存储。原生 macOS App 是通过版本化 XPC 连接的轻量客户端；关闭或退出 App 窗口不会终止后台 Service 或中断正在执行的本地任务。

---

## 架构拓扑

```text
ChatGPT 网页版 ───► Secure MCP Tunnel ┐
                                      ├─► CodexBridgeService ──► 本机 Codex 执行 (app-server)
Qwen Studio ────► 本机 HTTP `/mcp` ───┘   (MCP Gateway 网关)   └─► 独立 Supervisor 监督
CodexBridge.app ─► Mach XPC ──────────┘
```

### 模块单向依赖流

```text
CodexBridge.app → BridgeServiceAppShell → BridgeIPC → CodexBridgeService
CodexBridgeService → BridgeServiceHost
BridgeServiceHost → BridgeServiceCore / BridgeServiceApplication / BridgeMCP
                  → BridgeCodexService / BridgeTunnel / BridgeSecurity / BridgeDirectCommand
BridgeCodexService → BridgeCodexRPC
BridgeDirectCommand → BridgeServiceCore / BridgeProjects / BridgeSecurity
BridgeMCP → Service API
BridgeLegacyImport → BridgeServiceCore + 旧项目模型读取边界
```

---

## 核心特性

### 1. 统一的多客户端 MCP 网关 (MCP Gateway)
- **ChatGPT 网页版**：通过 OpenAI 官方 Secure MCP Tunnel 安全接入。
- **Qwen Studio (通义千问桌面版) 及本地客户端**：通过稳定的本机回环 Streamable HTTP 端点 (`/mcp`) 直接接入，各客户端拥有独立 Keychain 凭证、独立的 Profile 与会话生命周期回收机制。
- **灵活暴露模式**：每个 MCP 客户端均支持独立的只读 (Read-Only) 或完整操作 (Full-Action) 暴露模式。

### 2. 本机 Codex 执行与透明监督
- 通过官方 `codex app-server` stdio 协议与本机 Codex 实例通信。
- 独立的 **Supervisor** 监督会话，提供透明的观察、评审和进度跟踪，且 Supervisor 异常绝不中断 Codex 主执行流程。
- 实时对话流式同步（`item/agentMessage/delta`、`item/reasoning/textDelta`、工具调用状态流）至原生桌面客户端。

### 3. Direct 本地命令与受控 Git 提交
- **Direct 进程会话**：每个项目管理独立活跃进程组，结构化 argv 精确/前缀匹配，`posix_spawn` 原子创建，支持孤儿进程自动清理与 LRU/TTL 淘汰。
- **命令安全策略**：支持 `denied`（禁用）、`safe`（安全内置命令如 `ls/find/grep/rg` 且参数级路径受限）与 `full`（完整模式），配合用户白名单与黑名单。
- **文件与 Patch 操作**：精确的项目文件读写、乐观锁版本冲突检测 (`revision_conflict`)、受限 unified diff / patch 语法应用与敏感密钥泄露拦截。
- **受控 Git 提交**：`direct_git_commit` 使用隔离的临时 index 暂存变更，拒绝破坏性操作（`amend`/`push`/历史改写），并在暂存前严格检测敏感文件与密钥。

### 4. Skill Action 契约与网络沙盒隔离
- 完整 YAML Frontmatter 解析（`SKILL.md`），基于显式 Action 契约暴露能力。
- 细粒度网络声明：声明 `denied` 的脚本自动在 `sandbox-exec` 禁网沙盒中运行；`unspecified` 按保守策略走项目权限与本机审批。
- 内置 `agent-reach` 等只读 Skill 适配器，支持安全查询与外部检索。

### 5. 原生 macOS 桌面体验 (SwiftUI + AppKit)
- **实时流式对话**：打字机式实时渲染，支持可折叠思考链区块与结构化工具调用卡片。
- **本机审批中心**：危险的文件修改与 Direct 操作触发桌面本机审批，支持一次性 payload digest 校验、过期时间与冷却防刷机制。
- **工作台内嵌浏览器**：持久化 `WKWebView`，离开工作台支持会话保留复用，支持原生文件下载面板拦截与外部 URL 防跳出。

---

## 安全边界与产品原则

- **零云端存储**：无开发者运营的云端服务器、数据库、计费系统或远程源码同步。
- **凭据绝不上报**：Bridge 绝不读取、记录、导出 Codex 的 `auth.json`、Token、登录 Cookie 或 Keychain 私钥。
- **本机唯一授权**：ChatGPT、Qwen Studio 与 Supervisor 均无权批准危险操作——审批权限完全归属于本地 Mac 用户。
- **工作区边界封闭**：MCP 工具严格限制在用户显式注册的项目目录内（经由规范绝对路径、设备 device 与 inode 严格校验），拒绝符号链接逃逸与越权访问。
- **写并发互斥**：同一项目同一时间至多允许一个活跃的工作区写任务；只读任务支持完全并发。

---

## 快速上手

### 环境要求
- macOS 14.0 或更高版本
- Swift 6 / Xcode 16+ 编译工具链
- 本地已安装 **Codex 桌面端**（或具备 `app-server` 支持的 Codex 环境）
- Node.js（用于运行 MCP Inspector 验收门禁）

### 构建与运行

1. **本地开发构建**：
   ```bash
   Scripts/with-xcode.sh xcodebuild \
     -project CodexBridge.xcodeproj \
     -scheme CodexBridge \
     -configuration Debug \
     -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath .build/Xcode \
     build CODE_SIGNING_ALLOWED=NO
   ```
2. **首次启动**：
   - 打开 `CodexBridge.app`，应用会自动注册并连接内置的 `CodexBridgeService` 后台 LaunchAgent。
   - 若系统弹出提示，请在 **macOS 系统设置 → 通用 → 登录项与扩展** 中允许后台运行。
3. **注册项目**：
   - 在应用内点击添加本地项目目录。项目根目录将被记录并持续校验其设备号与 inode 标识。
4. **接入 MCP 客户端**：
   - **ChatGPT 网页版**：在“连接”页面配置 Secure MCP Tunnel，输入 Tunnel ID 与 Runtime Key（仅存入系统 Keychain），并在 ChatGPT 开发者模式中添加该 MCP 服务。
   - **Qwen Studio**：在“连接”页面开启 Qwen Studio，复制本地配置 JSON 并填入 Qwen Studio MCP 设置中即可开始对话。

---

## 代码仓库结构

```text
App/                              macOS 原生客户端入口
CodexBridge.xcodeproj/            包含 App 与后台 Service Target 的 Xcode 工程
Packages/BridgeCore/
  Sources/BridgeServiceCore/      单 SQLite 数据存储：项目、任务、设置、事件
  Sources/BridgeCodexRPC/         Codex app-server 协议适配与进程通信
  Sources/BridgeCodexService/     ExecutionManager、SupervisorManager、本机审批与协调器
  Sources/BridgeServiceApplication/ MCP 与 XPC 共用的轻量应用服务层
  Sources/BridgeMCP/              受限 MCP 网关服务端（ChatGPT 与 Qwen Studio Profile）
  Sources/BridgeIPC/              版本化、有界的 XPC 通信 DTO 与客户端 Hub
  Sources/BridgeServiceHost/      后台 Service 组合根、XPC/MCP/Tunnel 生命周期管理
  Sources/BridgeServiceAppShell/  纯 UI 客户端：项目管理、会话列表、状态展示、审批与工作台
  Sources/BridgeDirectCommand/    Direct 命令执行会话、进程隔离与受控 Git 提交
  Sources/BridgeSkills/           Skill 发现、YAML Frontmatter 解析与 Action 沙盒
  Sources/BridgeTunnel/           Secure MCP Tunnel 进程生命周期与健康检查
  Sources/BridgeLegacyImport/     一次性只读旧版本配置迁移
  Sources/BridgeSecurity/         路径规范化、设备/Inode 校验与敏感密钥过滤
  Sources/BridgeFiles/            受限项目文件检索与分页读取
  Sources/BridgeProjects/         项目注册数据模型
Scripts/                          构建、代码检查、测试、Tunnel 校验与发布脚本
docs/                             架构规范、兼容性矩阵、开发者指南与交接文档
```

---

## 开发与测试验证

所有提交均需通过完整的测试套件与严格的代码格式检查：

```bash
# 运行 Swift Package 单元测试与集成测试
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore

# 严格 swift-format 代码风格检查
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive \
  Packages/BridgeCore/Sources Packages/BridgeCore/Tests App

# 官方 MCP Inspector 验收门禁
Scripts/verify-mcp-inspector.sh

# Tunnel helper 兼容性与配置检查
Scripts/test-tunnel-helper-config.sh
```

**当前验证基线**：Swift 6 严格并发检查下，28 个测试包共 730+ 项测试全部通过 (0 失败)，并通过 MCP Inspector 2.1.0 与官方 tunnel-client 兼容门禁。

---

## 相关文档

- [`docs/CHATGPT_DEVELOPER_MODE.md`](./docs/CHATGPT_DEVELOPER_MODE.md) — ChatGPT 开发者模式与 Tunnel 配置指南。
- [`docs/COMPATIBILITY.md`](./docs/COMPATIBILITY.md) — Codex、MCP 与 macOS 兼容性矩阵。
- [`docs/DEPENDENCIES.md`](./docs/DEPENDENCIES.md) — 第三方依赖版本与开源协议清单。
- [`docs/TUNNEL_CLIENT_INTEGRATION.md`](./docs/TUNNEL_CLIENT_INTEGRATION.md) — Tunnel helper 集成与密钥传递契约。
- [`docs/RELEASE.md`](./docs/RELEASE.md) — 打包、签名、公证与发布流程。

---

## 开源协议与安全声明

- **开源协议**：本项目基于 [Apache License 2.0](./LICENSE) 开源。第三方组件声明参见 [NOTICE](./NOTICE)。
- **隐私与安全**：详情参见 [PRIVACY.md](./PRIVACY.md) 与 [SECURITY.md](./SECURITY.md)。请勿在 Issue 或报告中附带任何 Token、密钥、Cookie 或敏感源码。

