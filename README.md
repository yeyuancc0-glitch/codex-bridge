# Codex Bridge

<p align="center">
  <b>简体中文</b> | <a href="./README_en.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B%20%7C%20Windows%2010%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-6.0%20Strict-orange?style=flat-square&logo=swift" alt="Swift 6">
  <img src="https://img.shields.io/badge/Protocol-MCP%20Gateway-green?style=flat-square" alt="MCP">
  <img src="https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square" alt="License">
</p>

**Codex Bridge** 是一个**零开发者云端服务器、个人自托管、纯本地优先**的 macOS 与 Windows 桥接工具。它通过标准的 Model Context Protocol (MCP)，将 **ChatGPT 网页版**、**通义千问桌面版 (Qwen Studio)** 等 AI 客户端直接连接到你本地的 **Codex** 执行引擎，让云端顶尖大模型安全驱动本地代码开发与环境交互。

---

## 🌟 核心价值与亮点

- 🔒 **纯本地自托管（Zero-Cloud）**：无任何第三方云服务器中转、无开发者数据库、无账号系统，代码与凭据全程不出本机。
- ⚡ **原生多客户端 MCP 网关**：
  - **ChatGPT 网页版**：通过 OpenAI 官方 Secure MCP Tunnel 端到端安全穿透。
  - **Qwen Studio (通义千问桌面版)**：通过本地回环 Streamable HTTP `/mcp` 端点极速连接，一键复制配置即用。
- 🤖 **双重执行模式**：
  - **Codex 深度模式（推荐）**：任务委托给本机 Codex 引擎（支持多轮对话、工具链、独立 Supervisor 监督与打字机式实时流）。
  - **Direct 直接操作模式**：MCP 客户端直接进行文件读写、Patch 补丁应用、受控 Git 提交与安全命令执行（受本机桌面审批保护）。
- 🛡️ **本地唯一授权（Local-Only Approval）**：无论 AI 多么强大，任何高危文件写入、命令执行与 Git 提交，**必须由本机用户在桌面 UI 中手动点击允许**。
- 🖥️ **原生桌面体验**：macOS 使用 SwiftUI + AppKit，Windows 使用 WinUI 3 + WebView2；独立后台 Service 不把任务生命周期交给 UI。

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
            │  ├─ 统一 MCP 网关 (只读/完整模式)               │
            │  ├─ 进程与会话管理 (Direct Process Session)   │
            │  ├─ 单 SQLite 存储 (任务、项目、设置)          │
            │  └─ 本机安全与审批中心 (Local Approval Center)│
            └──────┬────────────────────────┬──────────────┘
                   │ XPC / 每用户 Named Pipe│ stdio JSON-RPC
                   ▼                        ▼
      ┌────────────────────────┐  ┌────────────────────────┐
      │ CodexBridge 桌面 App   │  │   本机 Codex 执行引擎    │
      │ (macOS / Windows 原生) │  │  (app-server + 独立监督)│
      └────────────────────────┘  └────────────────────────┘
```

---

## 🚀 两种核心工作流

### 1. Codex 深度编码工作流（主推模式）
```text
ChatGPT / Qwen  ──[submit_task]──►  CodexBridgeService  ──►  本地 Codex 引擎
      ▲                                                          │
      │                                                          ▼
  [get_task] 实时获取进度与终态报告   ◄────  打字机流式同步 / 独立 Supervisor 监督
```
- **适用场景**：复杂功能开发、大型代码重构、多步调试与测试。
- **特性**：自动绑定 Codex Thread，支持思考链展示、工具执行进度可视化，后台异步执行，退出 App 任务不中断。

### 2. Direct 敏捷直接操作工作流（即时修改）
```text
ChatGPT / Qwen  ──[direct_write_file]──►  本机桌面审批弹窗 (Payload Digest 签名校验)
                                                    │
                                           [用户点击 允许 / 拒绝]
                                                    │
                                                    ▼
                                          原子写入本地工作区文件
```
- **适用场景**：快速修改单个配置文件、应用小型 Patch、查看目录结构、执行受限只读命令。
- **特性**：单次有效签名凭据、防刷冷却机制、支持受控 `direct_git_commit`（隔离临时 index，敏感文件自动防泄漏）。

---

## 🛠️ 快速开始

### Windows：下载安装

1. 打开 [GitHub Releases](https://github.com/yeyuancc0-glitch/codex-bridge/releases)，普通 Intel/AMD 电脑下载名称含 `Windows-x64` 的 `Setup.exe`；Windows on ARM 设备下载名称含 `Windows-arm64` 的 `Setup.exe`。
2. 双击安装。安装器按当前用户安装到 `%LOCALAPPDATA%\Programs\CodexBridge`，不需要管理员权限。
3. 当前 GitHub 开源构件未做商业代码签名，Windows 可能显示“未知发布者”或 SmartScreen 提示。确认下载来源与 Release 中的 `SHA256SUMS.txt` 后，可选择“更多信息”→“仍要运行”。
4. 从开始菜单启动 **Codex Bridge**。卸载可使用 Windows“已安装的应用”；升级直接运行新版安装器，Service 数据会保留。

可在 PowerShell 中运行 `Get-FileHash .\下载的文件 -Algorithm SHA256`，将结果与 Release 的 `SHA256SUMS.txt` 对照。

Windows 10 版本 1809 或更高版本受支持，32 位 x86 Windows 不受支持；固定 WebView2 Runtime 已包含在发行包内。本机还需自行安装并登录 Codex，或让 `codex` 命令可被 Bridge 发现，发行包不包含 Codex。

### macOS：从源码构建

- **操作系统**：macOS 14.0 (Sonoma) 或更高版本（支持 Apple Silicon 与 Intel）。
- **Codex 环境**：本地已安装并登录 **Codex 桌面端**（或系统 PATH 具备可执行的 `codex` 命令）。
- **编译工具**：Xcode 16+ / Swift 6.0 工具链。

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

### 添加本地项目
在 App 中点击 **添加项目**，选择你允许 AI 访问的本地工程目录。Bridge 将严格锁定该目录的绝对路径、设备 ID 与 Inode，防止符号链接逃逸。

### 连接你的 AI 客户端

#### 方式 A：连接 ChatGPT 网页版
1. 在 Bridge App 的“连接”页面选择 **Secure MCP Tunnel**，填入你的 OpenAI `Tunnel ID` 与 `Runtime Key`（密钥安全存入系统凭据存储）。
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
| **本地唯一审批** | 外部 AI、Supervisor 均无权代替用户授权，高危操作必须由本机桌面 UI 中的用户人工确认。 |
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
Windows/CodexBridge.App/          Windows 原生客户端 (WinUI 3 + WebView2)
Windows/Installer/                Windows 每用户 EXE 安装器定义
Packages/BridgeCore/
  Sources/BridgeServiceCore/      单 SQLite 数据层 (项目、任务、设置、事件)
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

- **当前验证基准**：Swift 6 严格并发检查下，**28 个测试包、730+ 项测试 100% 通过（0 failures）**，并通过 MCP Inspector 2.1.0 与官方 tunnel-client 严格门禁。

---

## 📚 详细文档

- [ChatGPT Developer Mode 接入指南](./docs/CHATGPT_DEVELOPER_MODE.md)
- [系统与环境兼容性矩阵](./docs/COMPATIBILITY.md)
- [依赖版本与开源许可证明](./docs/DEPENDENCIES.md)
- [Secure Tunnel Helper 对接技术规范](./docs/TUNNEL_CLIENT_INTEGRATION.md)
- [构建、签名与发布流程](./docs/RELEASE.md)

---

## 📄 开源协议与隐私

- **开源协议**：本项目基于 [Apache License 2.0](./LICENSE) 开源。第三方依赖版权声明参见 [NOTICE](./NOTICE)。
- **隐私与安全策略**：详情参见 [PRIVACY.md](./PRIVACY.md) 与 [SECURITY.md](./SECURITY.md)。请勿在 Issue 或讨论中公开私钥、Token 或敏感项目源码。
