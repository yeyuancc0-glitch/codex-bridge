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

**Codex Bridge** is a **zero-cloud, personal self-hosted, local-first** macOS bridge. Through the standard Model Context Protocol (MCP), it connects **ChatGPT Web**, **Qwen Studio**, and other MCP clients directly to your local **Codex** execution engine—enabling world-class cloud AI models to safely power local development and environment automation.

---

## 🌟 Key Highlights & Core Values

- 🔒 **Zero Cloud Footprint**: No third-party relay servers, no developer databases, and no account tracking. All code and credentials remain entirely on your local Mac.
- ⚡ **Native Multi-Client MCP Gateway**:
  - **ChatGPT Web**: Connects end-to-end via OpenAI's official Secure MCP Tunnel.
  - **Qwen Studio & Local Clients**: Connects lightning-fast via a stable loopback Streamable HTTP `/mcp` endpoint with one-click JSON configuration.
- 🤖 **Dual Execution Pathways**:
  - **Codex Deep Mode (Recommended)**: Delegates tasks to the local Codex engine (supporting multi-turn discussions, tool execution, independent Supervisor critique, and typewriter live streaming).
  - **Direct Mutation Mode**: Direct file edits, patch applications, controlled Git commits, and sandboxed command execution (protected by desktop prompt approvals).
- 🛡️ **Local-Only Approvals**: No matter how intelligent the AI is, any dangerous file write, command execution, or Git commit **must be explicitly approved by the local Mac user via a native desktop dialog**.
- 🖥️ **Native macOS Experience (SwiftUI + AppKit)**: Standalone LaunchAgent daemon continues running when the UI is closed; the built-in workbench features real-time streaming, collapsible reasoning blocks, and structured tool-call cards.

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
            │  ├─ Unified MCP Gateway (Read-Only/Full)     │
            │  ├─ Direct Process & Session Management      │
            │  ├─ Single SQLite Store (Tasks, Projects)    │
            │  └─ Local Action Approval Center             │
            └──────┬────────────────────────┬──────────────┘
                   │ Mach XPC IPC           │ stdio JSON-RPC
                   ▼                        ▼
      ┌────────────────────────┐  ┌────────────────────────┐
      │    CodexBridge.app     │  │   Local Codex Engine   │
      │  (Native macOS Shell)  │  │(app-server + Supervisor│
      └────────────────────────┘  └────────────────────────┘
```

---

## 🚀 Two Core Workflows

### 1. Codex Deep Execution Workflow (Primary Path)
```text
ChatGPT / Qwen  ──[submit_task]──►  CodexBridgeService  ──►  Local Codex Engine
      ▲                                                          │
      │                                                          ▼
  [get_task] Poll progress & final report   ◄────  Typewriter streaming / Supervisor critique
```
- **Best for**: Feature implementations, large refactors, multi-step debugging, and automated testing.
- **Features**: Automatic Codex thread binding, live reasoning chain display, tool progress visualization, and uninterrupted background execution upon app exit.

### 2. Direct Agile Mutation Workflow (Instant Edits)
```text
ChatGPT / Qwen  ──[direct_write_file]──►  Desktop Approval Sheet (Payload Digest validation)
                                                    │
                                           [User clicks Allow / Deny]
                                                    │
                                                    ▼
                                          Atomic write to workspace file
```
- **Best for**: Fast configuration tweaks, small patch applications, repository inspection, and safe read-only commands.
- **Features**: Single-use signed approval grants, cooldown flood protection, and controlled `direct_git_commit` (isolated temporary index, sensitive credential protection).

---

## 🛠️ Quick Start

### 1. Prerequisites
- **Operating System**: macOS 14.0 (Sonoma) or later (Apple Silicon & Intel supported).
- **Codex Environment**: Installed and logged-in **Codex Desktop** (or executable `codex` command in system PATH).
- **Toolchain**: Xcode 16+ / Swift 6.0 toolchain.

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

### 3. Register Local Projects
Open the app and click **Add Project** to register your authorized workspace directories. Bridge binds the canonical path, device ID, and inode to eliminate symlink escapes.

### 4. Connect Your MCP Clients

#### Option A: Connect ChatGPT Web
1. In Bridge App's **Connections** tab, select **Secure MCP Tunnel**, and enter your OpenAI `Tunnel ID` and `Runtime Key` (securely stored in Keychain).
2. On ChatGPT Web → **Settings** → **Connected apps / Developer Mode** → **Add New Server**.
3. Choose **OpenAI Secure Tunnel**, enter the matching `Tunnel ID`, and set path to `/mcp`.
4. For step-by-step setup and prompt examples, see: [👉 ChatGPT Developer Mode Setup Guide](./docs/CHATGPT_DEVELOPER_MODE.md).

#### Option B: Connect Qwen Studio (Desktop)
1. In Bridge App's **Connections** tab, enable **Qwen Studio Support**.
2. Click **Copy MCP Config JSON**.
3. Paste the configuration into Qwen Studio's MCP settings to start chatting immediately!

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
Scripts/                          Build, signing, release & tunnel verification scripts
docs/                             Detailed technical specifications & developer guides
```

---

## 🛠️ Build from Source

The project requires full Xcode and uses the repository wrapper to select the correct toolchain:

```bash
# Build the Swift package
Scripts/with-xcode.sh swift build --package-path Packages/BridgeCore

# Strict swift-format code style check
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive \
  Packages/BridgeCore/Sources App Service

# Build an unsigned Debug app
Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj \
  -scheme CodexBridge \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode \
  build CODE_SIGNING_ALLOWED=NO
```

- Tests, fixtures, internal acceptance records, and locally generated data are not included in the public source snapshot.

---

## 📚 Documentation

- [ChatGPT Developer Mode Setup Guide](./docs/CHATGPT_DEVELOPER_MODE.md)
- [System & Environment Compatibility Matrix](./docs/COMPATIBILITY.md)
- [Pinned Dependencies & Licensing Evidence](./docs/DEPENDENCIES.md)
- [Secure Tunnel Helper Integration Contract](./docs/TUNNEL_CLIENT_INTEGRATION.md)
- [Packaging, Signing & Release Guide](./docs/RELEASE.md)

---

## 📄 License & Privacy

- **License**: Licensed under the [Apache License 2.0](./LICENSE). See [NOTICE](./NOTICE) for third-party acknowledgments.
- **Privacy & Security**: See [PRIVACY.md](./PRIVACY.md) and [SECURITY.md](./SECURITY.md). Never export tokens, keys, cookies, or sensitive project source in issues or reports.
