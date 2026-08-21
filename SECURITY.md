# Security Policy

Codex Bridge controls local developer tools and authorized source trees. Treat path escape, credential exposure, approval bypass, task replay and confused Thread/project binding as security issues.

## Supported versions

The project is pre-release and no public version is currently supported. Verified Codex CLI and dependency versions are recorded in the repository. Unknown Codex versions may be probed read-only but must not silently gain write capability.

## Reporting

Use the repository's Security tab to report a vulnerability privately. Do not open a public issue containing real credentials, private project paths or source code.

Never include:

- OpenAI or Tunnel Runtime Keys;
- Codex authentication files or session tokens;
- browser cookies or login databases;
- SSH/private keys;
- full project files, diffs or Thread history unrelated to the minimal reproduction.

Use synthetic fixtures and describe the affected version, trust boundary, expected behavior, actual behavior and reproducible steps.

## Non-negotiable boundaries

- The local MCP listener binds only to loopback and authenticates each supported client with its own Keychain-backed secret; remote ChatGPT access is carried by the pinned Tunnel helper.
- All remote project access uses an opaque `project_id` plus validated relative path.
- Symbolic links and filesystem identity are checked; sensitive files remain hard-denied.
- Policy code, not a model, is the authorization boundary.
- Supervisor cannot approve operations; a Supervisor failure only degrades supervision and does not take ownership of execution.
- Runtime Keys never enter Codex, logs, reports or support bundles.
- Non-idempotent app-server actions are reconciled after failure and are not blindly retried.

## Reverse-engineering resistance

No mechanism can make a locally delivered macOS binary impossible to reverse engineer: a user who controls the machine can eventually inspect code, attach a debugger or patch an unsigned copy. The goal here is to prevent useful secrets and trust decisions from being recovered from the client, and to make tampered release artifacts fail closed.

- Release builds use whole-module optimization, no testability, post-processing and symbol stripping; dSYM files stay outside the shipped App.
- Public release artifacts must pass `Scripts/verify-release-hardening.sh`. It verifies strict code signatures, Hardened Runtime, a real Developer ID Team ID, matching Team IDs for App/Service/helper and Universal 2 architecture coverage.
- Runtime Keys, MCP path secrets and Codex credentials remain in Keychain or anonymous file descriptors. They are never compiled into the binary, SQLite, logs or support bundles.
- Authorization remains in Service policy code. Obfuscation, anti-debugging and self-hash checks are not security boundaries and must not be used to store secrets or approve operations.

## Direct execution model

When the user explicitly asks ChatGPT itself to edit files or run commands (instead of delegating to Codex), the Service enforces the following boundaries:

- `direct_command_mode` per project (`denied` / `safe` / `full`) is a policy decision resolved by code, never by the model.
- Direct mutations run inside the same workspace gate as Codex write tasks: only one workspace-write owner per project at a time, so Direct and Codex never interleave writes.
- Direct file writes, destructive path actions, registered elevated commands and network-requiring commands each require a local approval that is bound to the exact payload digest plus `client_request_id`; approvals live in memory only and expire, so a Service restart cannot replay a stale grant.
- In safe mode, command execution is limited to explicitly registered project commands or validated built-in safe programs; arguments are structured and never shell-joined. Full mode still enforces hard-denied operations, project capabilities and local approval.
- Direct commands run in a dedicated process group with a bounded timeout, bounded stdin, and bounded output (head/tail); process groups are terminated on interrupt, shutdown and Service-crash orphan reaping.
- Direct sessions live in the background Service, not in the App, so quitting the App never stops a running local command; a tunnel disconnect only blocks new remote submissions and never cancels running local work.
