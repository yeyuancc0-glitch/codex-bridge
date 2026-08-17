# Changelog

All notable changes will be documented here. The project has not published a release.

## Unreleased

- Rebased V1 on a lightweight background Service architecture where the macOS App becomes a local client.
- Added `BridgeServiceCore`, a single-database project/task foundation with direct task state, display-only events, typed settings and project-level active write-task enforcement.
- Added real SQLite persistence, restart, transaction rollback, idempotency and cross-connection concurrency tests for the new Service path.
- Added the product, architecture, design-system and phase-accountability baselines.
- Added a versioned Codex app-server schema snapshot for CLI 0.147.0-alpha.6.5.
- Added a Swift 6 Stage 0 process/JSONL probe with real initialize and model-catalog verification.
- Added the first BridgeCore domain, security, RPC and persistence package structure.
