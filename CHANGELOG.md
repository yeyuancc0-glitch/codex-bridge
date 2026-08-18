# Changelog

All notable changes will be documented here. The project has not published a release.

## Unreleased

- Rebased V1 on a lightweight background Service architecture where the macOS App becomes a local client.
- Added `BridgeServiceCore`, a single-database project/task foundation with direct task state, display-only events, typed settings and project-level active write-task enforcement.
- Added real SQLite persistence, restart, transaction rollback, idempotency and cross-connection concurrency tests for the new Service path.
- Added `BridgeCodexService`, a standalone Codex execution path for new or existing Threads, Turn progress, exact steer/interrupt and local allow/deny approvals without the legacy Coordinator or Pipeline.
- Added an independent, non-blocking Supervisor path with bounded observation queues, exact-turn automatic steer, hard steer limits, advisory attention states and fail-open degradation that never terminates Codex execution.
- Added a lightweight MCP service API with 11-tool read-only and 22-tool full exposure, simplified task submission, direct task state, secure project files, exact-cwd Thread reads and real strict-SDK loopback acceptance without the legacy Coordinator or Pipeline.
- Added a standalone `codex-bridge-service` process with one composition root, private service data, stable Keychain MCP authentication, anonymous and launchd Mach XPC listeners, a versioned bounded IPC protocol and an App-side XPC client.
- Replaced the macOS App's in-process control plane with a ServiceManagement/XPC client UI for projects, Threads, tasks, local approvals and MCP exposure; quitting the UI now leaves the background Service and active tasks running.
- Moved Secure MCP Tunnel ownership into the background Service with Keychain-only Runtime Keys, versioned XPC configuration, bounded restart monitoring, loopback health endpoint ownership checks and a local App connection panel that never returns the key.
- Added a one-time read-only legacy configuration migration (`BridgeLegacyImport`) that imports old project configuration and the old Secure Tunnel ID into the new Service store, forces the migrated Tunnel off, never migrates Runtime Keys, commits atomically with an idempotent completion marker, leaves legacy files unchanged, and degrades to a fixed desensitized status instead of blocking Service startup.
- Added the product, architecture, design-system and phase-accountability baselines.
- Added a versioned Codex app-server schema snapshot for CLI 0.147.0-alpha.6.5.
- Added a Swift 6 Stage 0 process/JSONL probe with real initialize and model-catalog verification.
- Added the first BridgeCore domain, security, RPC and persistence package structure.
- Added a workspace mutation gate plus file revision digests so only one workspace-write owner runs per project.
- Added Direct workspace file mutation tools (`direct_write_project_file`, `direct_edit_project_file`, `direct_apply_project_patch`, `direct_manage_project_path`) that require explicit ChatGPT opt-in and local approval.
- Added per-project Direct command configuration (`denied`/`registered`/`safe` modes) with an App command editor and a read-only `list_project_commands` tool.
- Added full Direct Process Sessions (`BridgeDirectCommand`): registered/safe command policy with exact `argv` matching, per-project single sessions, process groups, bounded timeout/stdin/output, interrupt and Service-crash orphan reaping, plus `direct_exec_project_command`/`direct_read_command`/`direct_write_stdin`/`direct_interrupt_command`.
- Added the in-memory Direct approval center (`DirectActionApprovalCenter`) with payload-digest plus `client_request_id` one-time grants, expiry and restart invalidation, surfaced through XPC to the App for local approve/deny.
- Clarified MCP tool semantics so Codex remains the default execution path and Direct tools are explicit opt-in only, covered by read-only/full exposure tests.
- Covered cross-scenario failures: orphaned Direct processes are reaped on Service restart and tunnel disconnects never stop a running Direct command.
