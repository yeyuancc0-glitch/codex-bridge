# Codex Bridge

<p align="center">
  <a href="./README.md">简体中文</a> | <b>English</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-blue?style=flat-square&logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-6.0%20Strict-orange?style=flat-square&logo=swift" alt="Swift 6">
  <img src="https://img.shields.io/badge/Protocol-MCP%20Gateway-green?style=flat-square" alt="MCP">
  <img src="https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square" alt="License">
</p>

**Codex Bridge** is a **zero-cloud, personal self-hosted, local-first** macOS bridge and MCP gateway.

It is dedicated to **seamlessly connecting Chat clients with local engineering workspaces and Coding Agent engines**:
- 🌟 **Multi-Chat Client Ingress**: Connects **ChatGPT Web**, **Qwen Studio (Desktop)**, and other modern AI interfaces;
- 📂 **Direct Project Read/Write**: Empowers Chat clients to inspect file trees, read source code, apply Unified Diff patches, and execute controlled Git commits directly;
- 🤖 **Multi-Agent Orchestration**: Bridges local **Codex** and **OpenCode** execution engines for multi-turn autonomous coding;
- 🎯 **Sandboxed Skill System**: Supports standard `SKILL.md` contracts and `sandbox-exec` network isolation, enabling custom automation scripts and deep web research;
- 🛡️ **Local-Only Approvals**: Any high-risk file modifications, command executions, or Git commits require explicit manual confirmation via native macOS desktop dialogs. Code and credentials never leave your Mac.

---

## 🌟 Core Capability Matrix

```text
  【Chat Ingress】                                          【Capabilities & Execution】
┌──────────────────┐                                     ┌──────────────────┐
│   ChatGPT Web    │ ──(OpenAI Secure Tunnel)───────┐   ├─► Local Codex    │ (app-server + Supervisor)
└──────────────────┘                                │   ├──────────────────┤
┌──────────────────┐                                ├──►│ Local OpenCode   │ (ACP Protocol + Plan/Build)
│Qwen Studio Desktop│ ──(Local Loopback HTTP /mcp)──┘   ├──────────────────┤
└──────────────────┘                                    ├─► Direct Mutation│ (Inspect/Edit/Patch/Git)
                                                        ├──────────────────┤
                                                        └─► Skill System   │ (Action Contracts/Sandbox)
```

- 🌐 **Native Multi-Chat Ingress**:
  - **ChatGPT Web**: Connects end-to-end via OpenAI official Secure MCP Tunnel, allowing cloud models to safely drive local workspaces.
  - **Qwen Studio (Desktop)**: Connects lightning-fast via a stable loopback Streamable HTTP `/mcp` endpoint with one-click JSON configuration.
- 📂 **Direct Local Project Operations & Version Control**:
  - **Directory & Source Inspection**: Chat models can directly browse authorized workspace trees, retrieve file contents, and gather context.
  - **Atomic Edits & Unified Diff Patches**: Supports Bridge patch syntax and standard Unified Diff formats, strictly protected by desktop confirmation prompts.
  - **Controlled Git Commits**: Isolates commits using a temporary index, checks against secret leaks, and forbids destructive `push` or history rewrites.
- 🎯 **Sandboxed Skill Extension Ecosystem**:
  - **Standardized Contracts**: Follows `SKILL.md` specifications with full YAML frontmatter parsing and explicit Action contracts.
  - **Sandbox Isolation**: Integrates `sandbox-exec` network isolation, restricting network access by default for undeclared scripts.
- 🧩 **Unified Multi-Agent Orchestration**:
  - **Codex Deep Engine**: Communicates over official `codex app-server` stdio protocol, featuring multi-turn threads, subagent delegation, independent Supervisor critique, and typewriter live streaming.
  - **OpenCode ACP Engine**: Communicates over standard Agent Client Protocol (ACP) stdio, supporting native Plan / Build modes and dynamic model/reasoning effort adaptation.
- 🔒 **Zero Cloud Footprint (Zero-Cloud)**: No third-party relay servers, no developer databases, and no account tracking. All code and credentials remain strictly on your local machine.
- 🖥️ **Native macOS Architecture (SwiftUI + AppKit + LaunchAgent)**: Standalone LaunchAgent daemon keeps tasks running uninterrupted when the UI is closed; built-in workbench features real-time streaming, collapsible reasoning blocks, and structured tool-call cards.

---

## 🏗️ Architecture Topology

```text
┌────────────────────────┐      ┌────────────────────────┐
│      ChatGPT Web       │      │   Qwen Studio Client   │
│ (OpenAI Secure Tunnel) │      │ (Local HTTP /mcp Port) │
└───────────┬────────────┘      └───────────┬────────────┘
            │                               │
            └───────────────┬───────────────┘
                            ▼
            ┌──────────────────────────────────────────────┐
            │        CodexBridgeService (LaunchAgent)      │
            │  ├─ Unified MCP Gateway (ChatGPT / Qwen)     │
            │  ├─ Agent Task Runner (Codex & OpenCode)     │
            │  ├─ Direct Mutation & Git Tools              │
            │  ├─ Skill Execution Engine (BridgeSkills)    │
            │  ├─ Single SQLite Store (Tasks, Projects)    │
            │  └─ Local Action Approval Center             │
            └──────┬──────────────┬──────────────┬─────────┘
                   │              │              │
      Mach XPC IPC │    stdio RPC │    stdio ACP │  posix_spawn / sandbox-exec
                   ▼              ▼              ▼         ▼
      ┌──────────────────┐ ┌────────────┐ ┌────────────┐ ┌───────────────────┐
      │ CodexBridge.app  │ │Local Codex │ │Local       │ │ Direct File & Git/│
      │(Native Mac Shell)│ │(Deep Engine│ │  OpenCode  │ │ Skill Execution   │
      │                  │ │+Supervisor)│ │(ACP Engine)│ │                   │
      └──────────────────┘ └────────────┘ └────────────┘ └───────────────────┘
```

---

## 🚀 Four Core Workflows

### 1. Codex Deep Execution Workflow (Primary Path)
```text
ChatGPT / Qwen ──[submit_task]──► CodexBridgeService ──► Local Codex Engine (app-server)
      ▲                                                         │
      │                                                         ▼
  [get_task] Poll live progress & report  ◄──── Typewriter streaming / Supervisor critique
```
- **Best for**: Complex feature implementations, large refactors, multi-step debugging, and automated testing.
- **Features**: Automatic Codex thread binding, live reasoning chain display, tool progress visualization, and uninterrupted background execution upon app exit.

### 2. OpenCode ACP Workflow
```text
ChatGPT / Qwen / Workbench ──[provider_id=opencode]──► Local Approval Center
                                                         │
                                                         ▼
                                         OpenCode ACP (Plan / Build)
```
- **Best for**: Multi-model benchmarking, standard ACP-based agent execution, and switching between Plan (read-only) and Build (workspace-write) modes.
- **Features**: Dynamic model catalogs from ACP `session/new.configOptions`, native reasoning effort adaptation.

### 3. Direct Project Read/Write & Controlled Git Workflow
```text
ChatGPT / Qwen ──[direct_write_file]──► Desktop Approval Sheet (Payload Digest validation)
                                                  │
                                         [User clicks Allow / Deny]
                                                  │
                                                  ▼
                                        Atomic write to workspace file
```
- **Best for**: Fast configuration tweaks, small patch applications, workspace inspection, and safe read-only commands.
- **Features**: Single-use signed approval grants, cooldown flood protection, and controlled `direct_git_commit` (isolated temporary index, sensitive credential protection).

### 4. Skill Automation & Sandbox Workflow
```text
ChatGPT / Qwen ──[run_skill_action]──► Sandbox Enforcement (sandbox-exec network deny)
                                                │
                                       [Execute Action Script]
                                                │
                                                ▼
                                      Return structured receipt & output
```
- **Best for**: Running dedicated project helper scripts, automated data transformation, and internet research.
- **Features**: Automatic `SKILL.md` parsing, explicit Action contracts, dynamic execution deadlines, and sandboxed isolation.

---

## 🛠️ Quick Start

### 1. Prerequisites
- **Operating System**: macOS 14.0 (Sonoma) or later (Apple Silicon & Intel supported); Windows 10/11 x64 and ARM64 preview builds are available.
- **Agent Environment**:
  - **Codex**: Installed and logged-in **Codex Desktop** (or executable `codex` command in system PATH).
  - **OpenCode (Optional)**: Installed **OpenCode** CLI in system PATH.
- **Toolchain**: Xcode 16+ / Swift 6.0 toolchain; Windows uses Swift 6.3.3.

### 2. Build & Launch
```bash
# Clone the repository
git clone https://github.com/yeyuancc0-glitch/codex-bridge.git
cd codex-bridge

# Build and run locally
Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj \
  -scheme CodexBridge \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode \
  build CODE_SIGNING_ALLOWED=NO
```

Launching `CodexBridge.app` will automatically register and start the bundled `CodexBridgeService` LaunchAgent.

On Windows, build the service and desktop shell for the host architecture (x64 or ARM64):

```powershell
powershell -File Scripts\build-windows.ps1 -Test
```

The default output is a runnable portable directory under
`.build\windows-dist\<architecture>` plus a sibling
`codex-bridge-windows-<architecture>.zip`. The Windows chat surface requires the system
WebView2 Evergreen Runtime; the build stages the matching `WebView2Loader.dll` beside the
executables.

### 3. Register Local Projects & Skills
Open the app and click **Add Project** to register your authorized workspace directories. Bridge binds the canonical path, device ID, and inode to eliminate symlink escapes, automatically discovering any embedded Skills.

### 4. Configure Agent Engines
- **Codex Engine**: Ready out of the box upon detecting the local `codex` binary.
- **OpenCode Engine**: In Bridge, open **Settings → Local Agent Providers**, register the OpenCode executable path, and enable it after a successful probe.
- **DeepSeek Harness (experimental)**: Register the pinned ACP executable and an external `cordis.yml`. Keep `.env` in that profile directory and configure separate base URLs for the main model and Web Search; see the [DeepSeek Harness Setup Guide](./docs/DEEPSEEK_HARNESS_CONNECTION_GUIDE_en.md).

### 5. Connect Your Chat Clients

#### Option A: Connect ChatGPT Web
1. In Bridge App’s **Connections** tab, select **Secure MCP Tunnel**, and enter your OpenAI `Tunnel ID` and `Runtime Key` (securely stored in Keychain).
2. On ChatGPT Web → **Settings** → **Connected apps / Developer Mode** → **Add New Server**.
3. Choose **OpenAI Secure Tunnel**, enter the matching `Tunnel ID`, and set path to `/mcp`.
4. For step-by-step setup and prompt examples, see: [👉 ChatGPT Developer Mode Setup Guide](./docs/CHATGPT_DEVELOPER_MODE.md).

#### Option B: Connect Qwen Studio (Desktop)
1. In Bridge App’s **Connections** tab, enable **Qwen Studio Support**.
2. Click **Copy MCP Config JSON**.
3. Paste the configuration into Qwen Studio’s MCP settings to start chatting immediately!

---

## 🛡️ Security & Privacy Boundaries

| Security Pillar | Implementation Mechanism |
| :--- | :--- |
| **Local-Only Approval** | AI models and Supervisors cannot approve sensitive actions; approvals stay strictly with the Mac user via desktop sheets. |
| **Workspace Containment** | Operations are strictly constrained within registered project roots; access to sensitive locations (`~/.ssh`, `.env*`, `/etc`) is denied. |
| **Mutex Write Lock** | Exactly one active workspace-write task per project at a time (`project_busy` protection), preventing write conflicts. |
| **Controlled Git Commits** | `direct_git_commit` uses an isolated temporary index, validates against secret leakage, and forbids destructive `push` / `amend`. |
| **Skill Sandboxing** | Explicit Action contracts run under `sandbox-exec` network isolation when marked `denied`. |
| **Zero Credential Scraping** | Never reads, logs, or exports Codex `auth.json`, session tokens, or browser cookies. |

---

## 📂 Repository Map

```text
App/                              Native macOS client entry point (SwiftUI + AppKit)
CodexBridge.xcodeproj/            Xcode project containing App & Service LaunchAgent targets
Packages/BridgeCore/
  Sources/BridgeAgentCore/        Provider, installation, capability & execution contracts
  Sources/BridgeOpenCodeACP/      OpenCode ACP stdio adapter, model catalog & event normalization
  Sources/BridgeServiceCore/      Single SQLite store (Projects, tasks, settings, events)
  Sources/BridgeCodexRPC/         Codex app-server protocol adapter & stdio process broker
  Sources/BridgeCodexService/     ExecutionManager, Supervisor, coordinator & live streams
  Sources/BridgeServiceApplication/ Lightweight application service shared by MCP & XPC
  Sources/BridgeMCP/              Bounded MCP gateway (ChatGPT & Qwen Studio profiles)
  Sources/BridgeIPC/              Versioned, bounded XPC IPC hub
  Sources/BridgeServiceHost/      Background Service composition root & lifecycle manager
  Sources/BridgeServiceAppShell/  Pure UI shell: workbench, project manager, approval sheets
  Sources/BridgeDirectCommand/    Direct command execution, process sessions & controlled git
  Sources/BridgeSkills/           Skill discovery, YAML frontmatter & action sandboxing
  Sources/BridgeTunnel/           Secure MCP Tunnel process lifecycle & health checks
  Sources/BridgeSecurity/         Path canonicalization, device/inode validation & secret filters
Scripts/                          Build, lint, test, tunnel verification & release scripts
docs/                             Detailed technical specifications & developer guides
```

---

## 🧪 Development & Verification Baseline

This project adheres to rigorous engineering standards:

```bash
# Run package unit and integration tests
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore

# Strict swift-format code style check
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive \
  Packages/BridgeCore/Sources Packages/BridgeCore/Tests App

# Official MCP Inspector acceptance gate
Scripts/verify-mcp-inspector.sh

# Tunnel helper compatibility check
Scripts/test-tunnel-helper-config.sh
```

- **Verified Baseline**: Swift 6 strict-concurrency checks, the complete Package test suite, Universal 2 packaging, MCP Inspector 2.1.0, and tunnel-client gates are recorded against the current Release CI and release record.

---

## 📚 Documentation

- [ChatGPT Developer Mode Setup Guide](./docs/CHATGPT_DEVELOPER_MODE.md)
- [OpenCode Connection Guide](./docs/OPENCODE_CONNECTION_GUIDE.md)
- [DeepSeek Harness Setup Guide](./docs/DEEPSEEK_HARNESS_CONNECTION_GUIDE_en.md)
- [System & Environment Compatibility Matrix](./docs/COMPATIBILITY.md)
- [Pinned Dependencies & Licensing Evidence](./docs/DEPENDENCIES.md)
- [Secure Tunnel Helper Integration Contract](./docs/TUNNEL_CLIENT_INTEGRATION.md)
- [Packaging, Signing & Release Guide](./docs/RELEASE.md)

---

## 📄 License & Privacy

- **License**: Licensed under the [Apache License 2.0](./LICENSE). See [NOTICE](./NOTICE) for third-party acknowledgments.
- **Privacy & Security**: See [PRIVACY.md](./PRIVACY.md) and [SECURITY.md](./SECURITY.md). Never export tokens, keys, cookies, or sensitive project source in issues or reports.
