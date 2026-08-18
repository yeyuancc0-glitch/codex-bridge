# Changelog

All notable changes will be documented here. The project has not published a release.

## Unreleased

- Rebased V1 on a lightweight background Service architecture where the macOS App becomes a local client.
- Added `BridgeServiceCore`, a single-database project/task foundation with direct task state, display-only events, typed settings and project-level active write-task enforcement.
- Added real SQLite persistence, restart, transaction rollback, idempotency and cross-connection concurrency tests for the new Service path.
- Added `BridgeCodexService`, a standalone Codex execution path for new or existing Threads, Turn progress, exact steer/interrupt and local allow/deny approvals without the legacy Coordinator or Pipeline.
- Added an independent, non-blocking Supervisor path with bounded observation queues, exact-turn automatic steer, hard steer limits, advisory attention states and fail-open degradation that never terminates Codex execution.
- Added a lightweight MCP service API with 9-tool read-only and 12-tool full exposure, simplified task submission, direct task state, secure project files, exact-cwd Thread reads and real strict-SDK loopback acceptance without the legacy Coordinator or Pipeline.
- Added a standalone `codex-bridge-service` process with one composition root, private service data, stable Keychain MCP authentication, anonymous and launchd Mach XPC listeners, a versioned bounded IPC protocol and an App-side XPC client.
- Replaced the macOS App's in-process control plane with a ServiceManagement/XPC client UI for projects, Threads, tasks, local approvals and MCP exposure; quitting the UI now leaves the background Service and active tasks running.
- Moved Secure MCP Tunnel ownership into the background Service with Keychain-only Runtime Keys, versioned XPC configuration, bounded restart monitoring, loopback health endpoint ownership checks and a local App connection panel that never returns the key.
- Added a one-time read-only legacy configuration migration (`BridgeLegacyImport`) that imports old project configuration and the old Secure Tunnel ID into the new Service store, forces the migrated Tunnel off, never migrates Runtime Keys, commits atomically with an idempotent completion marker, leaves legacy files unchanged, and degrades to a fixed desensitized status instead of blocking Service startup.
- Added the product, architecture, design-system and phase-accountability baselines.
- Added a versioned Codex app-server schema snapshot for CLI 0.147.0-alpha.6.5.
- Added a Swift 6 Stage 0 process/JSONL probe with real initialize and model-catalog verification.
- Added the first BridgeCore domain, security, RPC and persistence package structure.
