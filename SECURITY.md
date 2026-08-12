# Security Policy

Codex Bridge controls local developer tools and authorized source trees. Treat path escape, credential exposure, approval bypass, task replay and confused Thread/project binding as security issues.

## Supported versions

The project is pre-release and no public version is currently supported. Verified Codex CLI and dependency versions are recorded in the repository. Unknown Codex versions may be probed read-only but must not silently gain write capability.

## Reporting

Open a private security advisory in the future GitHub repository once it exists. Until then, do not post a public proof of concept containing real credentials, private project paths or source code.

Never include:

- OpenAI or Tunnel Runtime Keys;
- Codex authentication files or session tokens;
- browser cookies or login databases;
- SSH/private keys;
- full project files, diffs or Thread history unrelated to the minimal reproduction.

Use synthetic fixtures and describe the affected version, trust boundary, expected behavior, actual behavior and reproducible steps.

## Non-negotiable boundaries

- MCP binds only to loopback and a random Keychain-backed path secret.
- All remote project access uses an opaque `project_id` plus validated relative path.
- Symbolic links and filesystem identity are checked; sensitive files remain hard-denied.
- Policy code, not a model, is the authorization boundary.
- Supervisor is read-only, offline and unable to approve operations.
- Runtime Keys never enter Codex, logs, reports or support bundles.
- Non-idempotent app-server actions are reconciled after failure and are not blindly retried.
