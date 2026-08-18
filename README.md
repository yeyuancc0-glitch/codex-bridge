# Codex Bridge

Codex Bridge is a local-first bridge between ChatGPT on the web and the user's local Codex installation. ChatGPT reads user-approved projects and Codex threads through MCP, submits a task to a local Codex execution session, and observes an independent Supervisor session. A native macOS app provides configuration, status and local approvals; the long-running backend runs as a separate user Service.

> Development status: the V1 background Service architecture is implemented and verified. `CodexBridgeService` runs as a bundled LaunchAgent and owns the MCP gateway, Secure Tunnel, Codex execution, the independent Supervisor, and the single SQLite store. The SwiftUI app is a pure Service client over versioned XPC; quitting the UI does not stop the Service or active tasks. The one-time read-only legacy configuration migration is wired into the Service composition root and covered by Service-level tests. The product is pre-release: the real ChatGPT Developer Mode closed loop, legacy control-plane removal and signed/notarized distribution are still pending user-side acceptance.

## V1 outcome

The V1 user flow is intentionally narrow:

1. The user starts Codex Bridge on a Mac and registers local project directories.
2. `CodexBridgeService` exposes a bounded MCP surface through Secure MCP Tunnel or another user-controlled HTTPS tunnel.
3. The user adds the MCP app in ChatGPT Developer Mode.
4. ChatGPT can read approved project files, list project-bound Codex threads, inspect current Codex models, submit a task, query progress, steer the active turn and stop the task.
5. The Service starts a Codex execution session and an independent Supervisor session for the same task.
6. Only the local user can approve or deny Codex permission requests in the macOS app.
7. Closing or quitting the UI does not stop the Service or active tasks.

The lightweight V1 plan is in [`docs/V1_LIGHTWEIGHT_REFACTOR_PLAN.md`](./docs/V1_LIGHTWEIGHT_REFACTOR_PLAN.md). Cross-window handoff notes are in [`docs/HANDOFF_*.md`](./docs/).

## Current architecture

```text
ChatGPT Web
    │ Secure MCP Tunnel
    ▼
CodexBridgeService
    ├── BridgeMCP / Service API
    ├── Codex execution (ExecutionManager)
    ├── independent Supervisor (SupervisorManager)
    ├── single SQLite store
    └── local approval broker
          │ Mach XPC (versioned, bounded)
          ▼
CodexBridge.app (BridgeServiceAppShell)
```

Module dependency direction is one-way:

```text
CodexBridge.app → BridgeServiceAppShell → BridgeIPC → CodexBridgeService
CodexBridgeService → BridgeServiceHost
BridgeServiceHost → BridgeServiceCore / BridgeServiceApplication / BridgeMCP
                  → BridgeCodexService / BridgeTunnel / BridgeSecurity
BridgeCodexService → BridgeCodexRPC
BridgeMCP → Service API
BridgeLegacyImport → BridgeServiceCore + legacy project model read boundary
```

`CodexBridgeService` is a standalone background process. It holds the MCP lifecycle, the Secure Tunnel, Codex execution, the independent Supervisor, and project/task/setting/event persistence. The app registers and connects to the Service through XPC; unregistering is an explicit user action, and quitting the app only disconnects the XPC client.

The repository still contains the legacy App-owned control plane (Coordinator, Pipeline, EventStore, Evidence, Verification, Reporting, Retention, backup/restore and notifications). These modules still build and run historical tests but are no longer the app's runtime path. They stay in place until the real ChatGPT closed loop and the migration are accepted, then are removed group by group behind a rollback tag. There is deliberately no long-term dual write between the old and new databases.

## Getting started

1. **Build or install.** Development: `Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO`. Public distribution is a separate credentialed process documented in [`docs/RELEASE.md`](./docs/RELEASE.md).
2. **First launch.** The app registers and connects the bundled `CodexBridgeService` background Service. macOS may ask to allow the background login item (System Settings → General → Login Items & Extensions). Quitting the app only disconnects the XPC client; it does not stop the Service or running tasks.
3. **Register projects.** Use the in-app directory picker. Each project root is captured with its canonical path, device and inode so identity is re-validated on every use.
4. **Codex login.** Complete the official Codex login through the in-app wizard. Bridge never reads or copies Codex `auth.json`; each isolated Supervisor HOME needs its own official login.
5. **Configure the Tunnel.** In Connections or the first-run wizard choose **Secure MCP Tunnel**, then enter the Tunnel ID and a restricted Runtime Key. The Runtime Key is written only to the macOS Keychain. Remote admission opens only after local MCP is ready, the helper is ready and the health check passes.
6. **ChatGPT Developer Mode.** Follow [`docs/CHATGPT_DEVELOPER_MODE.md`](./docs/CHATGPT_DEVELOPER_MODE.md): add the MCP app, enter the tunnel address, scan the tools, verify read-only and then full-action tools, and run a real task. MCP Inspector is not a substitute for this acceptance.
7. **Legacy migration.** On first Service start with a legacy data root, `BridgeLegacyImport` imports old project configuration and the old Tunnel ID once (Tunnel stays disabled; Runtime Key is not migrated). See [Legacy configuration migration](#legacy-configuration-migration).

## Documentation

- [`docs/CHATGPT_DEVELOPER_MODE.md`](./docs/CHATGPT_DEVELOPER_MODE.md) — user-side ChatGPT Developer Mode and Tunnel setup.
- [`docs/RELEASE.md`](./docs/RELEASE.md) — signing, notarization and release process.
- [`docs/COMPATIBILITY.md`](./docs/COMPATIBILITY.md) — Codex, MCP and tunnel compatibility status.
- [`docs/DEPENDENCIES.md`](./docs/DEPENDENCIES.md) — pinned dependency evidence.
- [`docs/TUNNEL_CLIENT_INTEGRATION.md`](./docs/TUNNEL_CLIENT_INTEGRATION.md) — tunnel helper integration and secret-passing contract.
- [`docs/V1_LIGHTWEIGHT_REFACTOR_PLAN.md`](./docs/V1_LIGHTWEIGHT_REFACTOR_PLAN.md) — lightweight V1 architecture plan and acceptance principles.

## Product boundary

- No developer-operated cloud server, account system, billing system or source-code database.
- Codex execution uses the user's existing official Codex/ChatGPT login. Bridge does not read or copy Codex authentication files.
- A separate transport credential may be required for Secure MCP Tunnel and must remain in Keychain.
- MCP can access only projects explicitly registered by the local user.
- MCP accepts opaque project identifiers and relative paths, never arbitrary absolute paths or a universal shell endpoint.
- ChatGPT and the Supervisor cannot approve Codex operations. Approval remains local-only.
- One project can have at most one active workspace-write task; read-only tasks may run concurrently.
- A Supervisor failure degrades supervision but must not terminate the Codex execution task.
- A lost execution process is reported as `unknown` or `interrupted`; a new Turn is never presented as recovery of the old Turn.

## Repository map

```text
App/                         Native macOS client entry point
CodexBridge.xcodeproj/       Native App project with the bundled Service target
Packages/BridgeCore/
  Sources/BridgeServiceCore/     Single SQLite store: projects, tasks, settings, events
  Sources/BridgeCodexRPC/        Verified Codex app-server protocol adapter
  Sources/BridgeCodexService/    ExecutionManager, SupervisorManager, local approval, coordinator
  Sources/BridgeServiceApplication/ Lightweight app service shared by MCP and XPC
  Sources/BridgeMCP/             Bounded MCP server (read-only 11 / full-action 22 tools)
  Sources/BridgeIPC/             Versioned, bounded XPC DTOs and client
  Sources/BridgeServiceHost/     Background Service composition root, XPC/MCP/Tunnel/lifecycle
  Sources/BridgeServiceAppShell/ Pure UI client: projects, threads, status, approvals
  Sources/BridgeTunnel/          Secure MCP Tunnel lifecycle
  Sources/BridgeLegacyImport/    One-time read-only legacy configuration migration
  Sources/BridgeSecurity/        Path, identity and outbound-content boundaries
  Sources/BridgeFiles/           Restricted project search and reads
  Sources/BridgeProjects/        Project registration models
  Sources/BridgeRuntime/         Legacy Codex runtime, frozen
  Sources/BridgeSupervisor/      Legacy supervisor source, frozen
  Sources/BridgeCoordinator/     Legacy task control plane, frozen
  Sources/BridgePipeline/        Legacy evidence/finalization pipeline, frozen
Scripts/                     Reproducible build and verification entry points
docs/                        Architecture, compatibility, migration and release notes
```

## New lightweight persistence foundation

`BridgeServiceCore` uses one SQLite database with four business areas:

```text
projects
tasks
task_events
settings
```

The `tasks` row is the current state source. `task_events` is append-only display and diagnostic history; it does not rebuild current state.

The database enforces the active workspace-write constraint with a partial unique index. An `unknown` write task intentionally retains the project write slot until the local user resolves it as failed or interrupted. Task state updates and their display event are committed in one transaction.

Current focused coverage verifies:

- project, task, setting and event persistence across reopen;
- task and event atomic rollback on invalid transitions;
- idempotent client request replay and conflict detection;
- cross-connection competition for one project write slot;
- concurrent read-only tasks and write tasks on different projects;
- restart conversion of in-flight tasks to `unknown` without releasing the write slot.

## Legacy configuration migration

On first Service startup with a legacy data root, `BridgeLegacyImport` performs a one-time, read-only migration from the old `~/Library/Application Support/CodexBridge/` (projects in `application.sqlite`, secure-tunnel ID in `onboarding.json`) into the new Service database:

- Migrates project IDs, names, the primary root identity (path, device, inode), access permissions, creation time, and the old Secure Tunnel ID with tunnel `enabled` forced to `0`.
- Does not migrate the Runtime Key, Codex login, old tasks, events, reports, Evidence, Verification, Supervisor ledger, patches, retention, backup state or notification ledger.
- Keeps offline external-drive projects by preserving their stored root identity; root identity is re-validated on actual use.
- Reads only through verified file descriptors, rejects `-journal`/`-wal`/`-shm` sibling files, and never reopens the database by path after validation.
- Commits projects, settings and the completion marker in one transaction; any failure rolls the whole batch back and leaves legacy files unchanged.
- Repeated startups are idempotent (`alreadyCompleted`), and existing new Service settings are never overwritten.
- A failed migration never blocks Service startup: it only records a fixed, desensitized degradation, with no paths or underlying error text exposed.
- The production Service explicitly enables the default legacy source; tests and custom compositions keep `legacyDataRootURL == nil` so they never read the real user directory.

## Development requirements

- macOS 14 or later
- Swift 6 / Xcode 27-compatible toolchain
- Codex CLI with `app-server` support
- Node.js for the pinned MCP Inspector gate
- Git

The repository currently uses a verified Xcode installation through `Scripts/with-xcode.sh`. The machine-wide `xcode-select` does not need to change.

```bash
Scripts/with-xcode.sh xcodebuild -version
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore --filter BridgeLegacyImportTests
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore --filter BridgeServiceHostTests
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive   Packages/BridgeCore/Sources Packages/BridgeCore/Tests App
Scripts/with-xcode.sh xcodebuild   -project CodexBridge.xcodeproj   -scheme CodexBridge   -configuration Debug   -destination 'platform=macOS,arch=arm64'   -derivedDataPath .build/Xcode   build CODE_SIGNING_ALLOWED=NO
Scripts/verify-mcp-inspector.sh
Scripts/test-tunnel-helper-config.sh
```

For another verified Xcode installation:

```bash
CODEX_BRIDGE_XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   Scripts/with-xcode.sh xcodebuild -version
```

Current verified baseline: the full package suite runs 730 tests across 28 test bundles with 0 failures, plus `swift-format --strict`, `git diff --check`, an arm64 Debug app build, the MCP Inspector 2.1.0 gate and the official arm64 tunnel-client compatibility gate.

## Remaining work

1. Real ChatGPT Developer Mode and Secure Tunnel task loop (requires the user's Codex login and Tunnel credentials; MCP Inspector is not a substitute).
2. Removal of the frozen legacy control plane after the real closed loop and migration are accepted (behind a rollback tag, group by group).
3. Release hardening: Developer ID signing, same-Team helper validation, Hardened Runtime, Universal 2, notarization, staple, Gatekeeper verification, SBOM and clean-machine acceptance.
4. Documentation review and a separate documentation commit once the code and release state are settled.

## Important platform limits

ChatGPT cannot connect directly to `127.0.0.1`; real use requires a remote HTTPS MCP endpoint or Secure MCP Tunnel. ChatGPT workspace permissions may also restrict mutation tools. The project therefore keeps separate read-only and full-action MCP exposure modes and never labels an action tool as read-only to bypass platform policy.

## Security reporting

Do not include Runtime Keys, Codex credentials, project source, cookies or private logs in reports. Security issues should describe the boundary and reproducible behavior without exporting user secrets. See [`SECURITY.md`](./SECURITY.md).

## Historical documents

The following documents describe the previous control-plane-heavy implementation and remain useful as hardening references, but they no longer define V1 scope:

- [`ChatGPT-Codex-Bridge-原生Swift本地开源版完整方案-V2.0.md`](./ChatGPT-Codex-Bridge-%E5%8E%9F%E7%94%9FSwift%E6%9C%AC%E5%9C%B0%E5%BC%80%E6%BA%90%E7%89%88%E5%AE%8C%E6%95%B4%E6%96%B9%E6%A1%88-V2.0.md)
- [`docs/PHASE_LEDGER.md`](./docs/PHASE_LEDGER.md)
- [`docs/FOLLOW_UP_PLAN.md`](./docs/FOLLOW_UP_PLAN.md)

## License

Codex Bridge is licensed under the [Apache License 2.0](./LICENSE). See [NOTICE](./NOTICE), [PRIVACY.md](./PRIVACY.md), [SECURITY.md](./SECURITY.md) and [CONTRIBUTING.md](./CONTRIBUTING.md).
