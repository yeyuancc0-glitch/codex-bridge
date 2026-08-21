# Codex Bridge

<p align="center">
  <a href="./README.md">简体中文</a> | <b>English</b>
</p>

Codex Bridge is a zero-cloud, personal self-hosted native bridge connecting **ChatGPT Web**, **Qwen Studio**, and other MCP clients directly to your local **Codex** installation on macOS. 

MCP clients inspect user-registered local projects, bind to Codex threads, submit tasks, and interact with your local development environment. A native macOS SwiftUI/AppKit application provides project management, configuration, real-time streaming conversations, and local approval controls; the long-running backend runs as a standalone user background Service (`CodexBridgeService`).

> **Development Status**: The V1 background Service architecture is fully implemented and verified. `CodexBridgeService` runs as a bundled LaunchAgent owning the MCP gateway, Secure Tunnel, loopback Streamable HTTP `/mcp` endpoint, Codex execution, independent Supervisor, and single SQLite store. The native macOS App is a pure Service client over versioned XPC; quitting or closing the App does not terminate the background Service or in-flight tasks.

---

## Architecture Topology

```text
ChatGPT Web ───► Secure MCP Tunnel ┐
                                   ├─► CodexBridgeService ──► Local Codex Execution (app-server)
Qwen Studio ───► Local HTTP `/mcp` ┘   (MCP Gateway)       └─► Independent Supervisor
CodexBridge.app ──► Mach XPC ──────┘
```

### Module Dependency Flow

```text
CodexBridge.app → BridgeServiceAppShell → BridgeIPC → CodexBridgeService
CodexBridgeService → BridgeServiceHost
BridgeServiceHost → BridgeServiceCore / BridgeServiceApplication / BridgeMCP
                  → BridgeCodexService / BridgeTunnel / BridgeSecurity / BridgeDirectCommand
BridgeCodexService → BridgeCodexRPC
BridgeDirectCommand → BridgeServiceCore / BridgeProjects / BridgeSecurity
BridgeMCP → Service API
BridgeLegacyImport → BridgeServiceCore + legacy project model read boundary
```

---

## Key Capabilities

### 1. Unified Multi-Client MCP Gateway
- **ChatGPT Web**: Connects securely via the official OpenAI Secure MCP Tunnel.
- **Qwen Studio & Local Clients**: Connects directly via a stable loopback Streamable HTTP endpoint (`/mcp`) with per-client credentials in Keychain and independent session lifecycle management.
- **Exposure Modes**: Flexible per-client Read-Only and Full-Action tool exposure modes.

### 2. Native Codex Execution & Supervision
- Direct communication with the local Codex instance via the official `codex app-server` stdio protocol.
- Independent **Supervisor** session for transparent observation, critique, and progress monitoring without hijacking execution.
- Real-time streaming conversation sync (`item/agentMessage/delta`, `item/reasoning/textDelta`, tool call progression) into the native desktop app.

### 3. Direct Workspace Actions & Controlled Git Commit
- **Direct Process Sessions**: Managed process lifecycle per project, structured argv matching, `posix_spawn` process group isolation, and orphan process cleanup.
- **Security Command Modes**: Configurable `denied`, `safe` (capability-validated built-in commands like `ls/find/grep/rg` with path containment), and `full` modes with custom whitelist/blacklist.
- **File & Patch Operations**: Granular project file read/write, optimistic concurrency conflict detection (`revision_conflict`), unified diff / patch application, and sensitive credential detection.
- **Controlled Git Commits**: `direct_git_commit` stages changes using isolated temporary index boundaries, prevents destructive actions (`amend`/`push`/history rewriting), and validates sensitive paths before commit.

### 4. Skill Action Contracts & Network Sandbox
- Full YAML Frontmatter parsing (`SKILL.md`) exposing explicit action contracts.
- Granular network declaration (`denied` runs under `sandbox-exec` network isolation; `unspecified` conservatively triggers local policy/approval).
- Built-in adapters for skills like `agent-reach` for safe, read-only external lookups.

### 5. Native macOS Desktop Experience (SwiftUI + AppKit)
- **Real-Time Streaming Conversation**: Typewriter-style live streaming, collapsible reasoning blocks, and structured tool-call cards.
- **Local Approval Center**: Dangerous mutations and direct actions trigger desktop approvals with single-use payload digests, expiration, and cooldown protections.
- **Embedded Workbench Browser**: Persistent `WKWebView` with login session reuse, native file download handling, and external URL scheme containment.

---

## Security Boundaries & Product Principles

- **Zero Cloud Footprint**: No developer-operated cloud servers, databases, account systems, or telemetry.
- **No Secret Scraping**: Bridge never reads, logs, or exports Codex `auth.json`, tokens, session cookies, or Keychain secrets.
- **Local-Only Approvals**: Neither ChatGPT, Qwen, nor the Supervisor can approve sensitive operations—authorization stays exclusively with the local Mac user.
- **Workspace Containment**: MCP tools operate strictly on explicit relative paths within user-registered project roots (canonical path, device, and inode validated).
- **Concurrency Safety**: At most one active workspace-write task per project at any time. Read-only tasks run concurrently.

---

## Getting Started

### Prerequisites
- macOS 14.0 or later
- Swift 6 / Xcode 16+ toolchain
- Local [Codex CLI](https://github.com/openai/codex) with `app-server` support
- Node.js (for MCP Inspector acceptance test gate)

### Build and Run

1. **Development Build**:
   ```bash
   Scripts/with-xcode.sh xcodebuild \
     -project CodexBridge.xcodeproj \
     -scheme CodexBridge \
     -configuration Debug \
     -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath .build/Xcode \
     build CODE_SIGNING_ALLOWED=NO
   ```
2. **First Launch**:
   - Launch `CodexBridge.app`. It automatically registers and connects to the bundled `CodexBridgeService` LaunchAgent.
   - Authorize background items in **macOS System Settings → General → Login Items & Extensions** if prompted.
3. **Register Projects**:
   - Add local project directories through the app. Project roots are captured with canonical path, device ID, and inode.
4. **Connect MCP Clients**:
   - **ChatGPT Web**: Configure Secure MCP Tunnel in the Connections tab, enter the Tunnel ID and Runtime Key (stored securely in Keychain), and connect via ChatGPT Developer Mode.
   - **Qwen Studio**: Enable Qwen Studio in Connections, copy the local JSON configuration into Qwen Studio MCP settings, and start chatting.

---

## Repository Map

```text
App/                              Native macOS client entry point
CodexBridge.xcodeproj/            Xcode project containing App and Service targets
Packages/BridgeCore/
  Sources/BridgeServiceCore/      Single SQLite store: projects, tasks, settings, events
  Sources/BridgeCodexRPC/         Verified Codex app-server protocol adapter
  Sources/BridgeCodexService/     ExecutionManager, SupervisorManager, local approval, coordinator
  Sources/BridgeServiceApplication/ Lightweight application service shared by MCP & XPC
  Sources/BridgeMCP/              Bounded MCP server (ChatGPT & Qwen Studio profiles)
  Sources/BridgeIPC/              Versioned, bounded XPC DTOs and client hub
  Sources/BridgeServiceHost/      Background Service composition root, XPC/MCP/Tunnel lifecycle
  Sources/BridgeServiceAppShell/  Pure UI client: projects, threads, status, approvals, workbench
  Sources/BridgeDirectCommand/    Direct command execution, process sessions & controlled git
  Sources/BridgeSkills/           Skill discovery, YAML frontmatter & action sandboxing
  Sources/BridgeTunnel/           Secure MCP Tunnel lifecycle & health checks
  Sources/BridgeLegacyImport/     One-time read-only legacy configuration migration
  Sources/BridgeSecurity/         Path canonicalization, device/inode validation & secret filters
  Sources/BridgeFiles/            Restricted project search and bounded reads
  Sources/BridgeProjects/         Project registration models
Scripts/                          Build, lint, test, tunnel verification & release scripts
docs/                             Architecture specs, compatibility matrices, guides
```

---

## Development & Verification

All changes must pass the full test suite and strict linting:

```bash
# Run package unit and integration tests
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore

# Strict swift-format check
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive \
  Packages/BridgeCore/Sources Packages/BridgeCore/Tests App

# Verified MCP Inspector gate
Scripts/verify-mcp-inspector.sh

# Tunnel helper compatibility check
Scripts/test-tunnel-helper-config.sh
```

**Verified Baseline**: 730+ tests across 28 test bundles with 0 failures under Swift 6 strict concurrency, plus clean MCP Inspector 2.1.0 and tunnel-client validation gates.

---

## Documentation

- [`docs/CHATGPT_DEVELOPER_MODE.md`](./docs/CHATGPT_DEVELOPER_MODE.md) — ChatGPT Developer Mode & Tunnel setup.
- [`docs/COMPATIBILITY.md`](./docs/COMPATIBILITY.md) — Compatibility matrix for Codex, MCP, and macOS.
- [`docs/DEPENDENCIES.md`](./docs/DEPENDENCIES.md) — Pinned dependency versions and license evidence.
- [`docs/TUNNEL_CLIENT_INTEGRATION.md`](./docs/TUNNEL_CLIENT_INTEGRATION.md) — Tunnel helper integration contract.
- [`docs/RELEASE.md`](./docs/RELEASE.md) — Packaging, signing, notarization, and distribution guide.

---

## License & Security

- **License**: Licensed under the [Apache License 2.0](./LICENSE). See [NOTICE](./NOTICE) for third-party acknowledgments.
- **Privacy & Security**: See [PRIVACY.md](./PRIVACY.md) and [SECURITY.md](./SECURITY.md). Never export tokens, keys, cookies, or sensitive project source in issues or reports.
