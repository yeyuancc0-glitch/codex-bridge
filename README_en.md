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

**Codex Bridge** is a self-hosted native macOS app and background service. It connects ChatGPT on the web, Qwen Studio, and a local Workbench to explicitly registered projects, then runs Codex, OpenCode, DeepSeek Harness, or Antigravity through one task, approval, conversation, and persistence system.

Bridge does not depend on a developer-operated relay, account service, or remote database. Requests still leave the Mac when you choose ChatGPT, a model API, or another provider; local-first does not mean that every task remains offline.

## Current capabilities

| Layer | Current implementation |
| --- | --- |
| ChatGPT web | OpenAI Secure MCP Tunnel; the packaged helper is managed by the background service |
| Qwen Studio | Loopback Streamable HTTP `/mcp`; the app copies an authenticated JSON profile |
| Codex | Default provider; `codex app-server --stdio`, Thread/Turn, live steer, interrupt, approvals, and Supervisor |
| OpenCode | ACP stdio, Plan/Build, runtime model and effort options, permissions, and queued follow-up prompts |
| DeepSeek Harness | Version-pinned ACP adapter, external `cordis.yml`, models/effort, Web/tools/subagents, execution evidence, and local approvals |
| Antigravity | `agy` stream-json CLI, Plan/Accept Edits, native sandbox, conversation resume, model/effort, and queued steer |
| Direct Workspace | Controlled reads/writes, revision-aware patches, structured commands, process sessions, and local Git commits |
| Skills | Safe `SKILL.md` discovery; only explicitly declared actions can run |

External agents must be explicitly registered, probed, enabled, and selected. A `submit_task` request without `provider_id` always uses Codex.

## Architecture

```text
ChatGPT Web                         Qwen Studio
    │ OpenAI Secure MCP Tunnel          │ localhost /mcp
    └──────────────────┬────────────────┘
                       ▼
              CodexBridgeService
              ├─ MCP / XPC application services
              ├─ one service.sqlite database
              ├─ project policy and local approvals
              ├─ provider task coordination
              ├─ Direct Workspace
              └─ Tunnel / Skill lifecycle
                       │
        ┌──────────────┼───────────────┬────────────────┐
        ▼              ▼               ▼                ▼
 Codex app-server  OpenCode ACP  DeepSeek Harness ACP  agy CLI
        │
        └─ Supervisor (Codex only)

CodexBridge.app ── XPC ──► CodexBridgeService
  Projects / Workbench / Connections / Settings / Approvals
```

The production service stores projects, settings, tasks, messages, and presentation events in one SQLite database. The app configures and observes the service and collects local approvals; it does not own provider, MCP, Tunnel, or Supervisor process lifecycles.

## Quick start

The [detailed Chinese user guide](./docs/USER_GUIDE.md) covers first-time setup, every provider, ChatGPT/Qwen, task control, permissions, and troubleshooting.

### 1. Install and start

- Requires macOS 14.0 or later.
- Release artifacts are split into `arm64` and `x86_64`; install the architecture matching the Mac.
- On first launch, approve the Codex Bridge background item when macOS asks, then return to the Overview page and refresh status.
- Closing the window does not stop the service. “Keep background service running after quitting the app” controls ⌘Q behavior and is enabled by default.

Build from source:

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

A normal Debug build may omit OpenAI's `tunnel-client`. Local MCP can still work, but ChatGPT Secure Tunnel requires a build whose Connections page reports that the helper is available.

### 2. Register a project and set hard policy

1. Open `Projects → Add` and select the project root.
2. Configure read, write, and network policy under Access and Execution Permissions.
3. Configure Direct command policy only if remote clients should run explicit local commands.

Project policy outranks Workbench defaults and task overrides. A project that denies writes cannot be upgraded by any provider request.

### 3. Select the remote-task default

In Workbench:

1. Select the project ChatGPT/Qwen should use.
2. Select `Read Only` or `Write` under the new-task control.

When a remote request omits `project_id`, the selected Workbench project is authoritative. An explicit ID must come from MCP `list_projects`, not from a display name. Remote clients should normally omit permission overrides and use the Workbench default.

### 4. Configure providers

- **Codex** is the default provider and is not registered under local agent connections. Complete official Codex/ChatGPT authentication, then select model, effort, access, and optional Fast tier in Settings. Bridge does not read Codex credentials.
- **OpenCode**: `Connections → Local Agent Engine Connections → Register Agent → OpenCode`; select the real `opencode` executable and Probe it. See the [OpenCode guide](./docs/OPENCODE_CONNECTION_GUIDE.md).
- **DeepSeek Harness**: build pinned tag `dsh-v0.1.1-rc.2`, register `packages/examples/acp-demo/lib/bin.js`, then select an external `cordis.yml`. The adjacent `.env` is loaded by Harness itself. See the [DeepSeek Harness guide](./docs/DEEPSEEK_HARNESS_CONNECTION_GUIDE_en.md).
- **Antigravity**: register the actual `agy` CLI, not the Desktop application. Bridge checks its version and current stream-json, mode, sandbox, conversation, model, and effort options.

After registering an external provider, enable it, then refresh its model catalog in Settings. Model IDs and effort values are provider-native and must not be guessed or aliased across providers.

### 5. Connect clients

#### ChatGPT web

1. Create or obtain a Tunnel in [OpenAI Platform Tunnels](https://platform.openai.com/settings/organization/tunnels).
2. Create a Restricted Runtime API Key in [OpenAI Platform API Keys](https://platform.openai.com/settings/organization/api-keys), granting only Tunnels `Read` and `Use`.
3. Enter the Tunnel ID and Runtime API Key in Bridge under `Connections → Remote AI Clients (OpenAI Secure Tunnel)`, then start the connection.
4. Follow the current OpenAI page to create an MCP app in ChatGPT Apps/Developer Mode. The common flow is to select **Tunnel**, select or paste the same Tunnel ID, scan tools, and create the app; the exact entry depends on the current account and Workspace UI.

The Runtime API Key is entered only in Bridge. Do not enter it, a localhost URL, `/mcp`, or the local Header Secret generated specifically for the ChatGPT profile in ChatGPT. See the [current Chinese ChatGPT guide](./docs/CHATGPT_DEVELOPER_MODE.md) and [OpenAI's Secure Tunnel guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels).

#### Qwen Studio

1. Open `Connections → Local MCP Client Channels`.
2. Enable Qwen Studio and select read-only or full tools.
3. Click “Copy Qwen JSON Configuration” and use Qwen's JSON import flow.

The JSON contains a local authentication header. Do not commit or publish it. Regenerating the credential invalidates every previous copy.

## Task, approval, and result semantics

```text
submit_task
    ↓
awaiting_local_approval (default)
    ↓ local Approve Start
starting → running ↔ waiting_for_codex_approval
               ↓
    completed / failed / interrupted

unknown: non-terminal state after losing the original run binding; requires local review
```

- Automatic approval for remote agent starts is disabled by default. Enabling it does not approve provider tool permissions or Direct operations.
- A project permits at most one active `workspace-write` task; read-only tasks can run concurrently.
- Terminal `get_task` state is authoritative. Follow its `wait_policy`; quiet output and an unchanged timestamp do not prove failure.
- Read `result_summary`, `failure_code`, `changed_files`, and provider bindings from the terminal `get_task` snapshot. The current MCP catalog does not expose `get_final_report`; `wait_policy.next_action=read_final_report` is a hint string, not a callable tool.
- OpenCode and Antigravity can resume a strictly matched historical session. DeepSeek Harness currently creates a fresh session for each task; historical-session resume is not supported. External-provider steer is generally a queued next prompt, not Codex in-flight steer.

## Security boundaries

| Boundary | Behavior |
| --- | --- |
| Registered projects | MCP accepts opaque project IDs; paths must stay inside a registered root and pass identity checks |
| Sensitive files | `.env*`, private keys, authentication files, browser data, and other sensitive paths are denied |
| Concurrent writes | Provider and Direct paths share one per-project write gate |
| Approval layers | Remote start approval, provider runtime permission, and Direct approval are separate |
| Credentials | Tunnel Runtime Key and per-client-profile local MCP secrets use Keychain; Bridge does not read provider credentials or the DSH `.env` |
| Network | Project policy, explicit task intent, and native provider policy all apply; Bridge does not pretend external providers have packet-level isolation |
| Git | `direct_git_commit` creates controlled local commits only; push, amend, reset, and history rewrites are disallowed |

## Repository layout

```text
App/                                  macOS application entry point
Packages/BridgeCore/Sources/
  BridgeServiceCore/                  SQLite, projects, settings, tasks, messages
  BridgeServiceApplication/           MCP/XPC application facade and policy
  BridgeCodexRPC/                      codex app-server adapter
  BridgeCodexService/                  Codex execution, Supervisor, conversation
  BridgeAgentCore/                     provider, installation, capability contracts
  BridgeACP/                           shared ACP transport and request broker
  BridgeOpenCodeACP/                   OpenCode adapter
  BridgeDeepSeekHarnessACP/            DSH adapter and packaged profile
  BridgeAntigravityCLI/                Antigravity CLI adapter
  BridgeMCP/                           single MCP control plane
  BridgeDirectCommand/                 Direct commands, Git, processes, approvals
  BridgeSkills/                        skill discovery and explicit actions
  BridgeTunnel/                        Secure MCP Tunnel lifecycle and health
  BridgeIPC/                           versioned XPC DTOs and client
  BridgeServiceHost/                   background-service composition root
  BridgeServiceAppShell/               Workbench, project, connection, settings UI
Scripts/                              build, validation, packaging, release scripts
docs/                                 user and developer documentation
```

## Development and validation

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

Packaging, installation, and signing only prove artifact state. Real ChatGPT, Qwen, provider login, network, tool, and approval behavior still requires manual acceptance with the corresponding accounts.

## Documentation

- [Detailed user guide (Chinese)](./docs/USER_GUIDE.md)
- [ChatGPT Developer Mode guide (Chinese)](./docs/CHATGPT_DEVELOPER_MODE.md)
- [OpenCode connection guide (Chinese)](./docs/OPENCODE_CONNECTION_GUIDE.md)
- [DeepSeek Harness connection guide](./docs/DEEPSEEK_HARNESS_CONNECTION_GUIDE_en.md)
- [Compatibility matrix](./docs/COMPATIBILITY.md)
- [Secure Tunnel integration notes](./docs/TUNNEL_CLIENT_INTEGRATION.md)
- [Build, signing, and release](./docs/RELEASE.md)
- [Dependencies and licenses](./docs/DEPENDENCIES.md)

## License and security reports

Licensed under [Apache License 2.0](./LICENSE); third-party notices are in [NOTICE](./NOTICE). See [PRIVACY.md](./PRIVACY.md) and [SECURITY.md](./SECURITY.md) for privacy and vulnerability reporting. Never publish API keys, tokens, cookies, `.env` files, or sensitive project source in issues, logs, or screenshots.
