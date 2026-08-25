# Secure MCP Tunnel Helper Integration

This document defines the process boundary used by `BridgeTunnel`. The current supply pin is the official public OpenAI `tunnel-client` v0.0.10 release at commit `105e17a79a36e4e5c897fd698ed2b8dbf935b144`, rechecked on 2026-08-17. OpenAI's Platform Tunnels page remains the source of truth for the version currently supported by the control plane; release packaging must recheck that page before distribution rather than assuming this repository pin remains current forever.

## Trust and packaging

- Pin v0.0.10 and validate both official macOS archives against the SHA-256 values in `docs/DEPENDENCIES.md` before extracting either executable.
- The v0.0.10 platform archives each contain exactly one thin `tunnel-client` executable. The supply build combines the verified arm64 and amd64 files into a derived Universal 2 helper and records its unsigned SHA-256.
- The upstream arm64 executable is ad-hoc linker-signed and has no Team Identifier; the amd64 executable is not suitable as the final application trust identity. Release packaging signs the derived Universal 2 helper with the same Developer ID Team as the containing App, recomputes the post-sign hash into an App-signature-covered resource, then signs and notarizes the containing App.
- Download the Apache-2.0 LICENSE from the pinned source commit and validate its digest. Preserve the project NOTICE material.
- Runtime verification opens the helper through `O_NOFOLLOW`, hashes that exact file descriptor against the externally trusted post-sign digest, starts it suspended, and resumes it only after the running `SecCode` matches the host Team requirement and the static CDHash read from the same descriptor.
- The App never downloads an unverified “latest” helper at runtime.

### Windows package supply

Windows x64 and ARM64 Inno Setup EXE installers stage the official v0.0.12 architecture archives. Packaging validates the external archive, `tunnel-client.exe`, and `cloudflared.exe` SHA-256 values recorded in `docs/DEPENDENCIES.md`, rejects any unexpected ZIP entry, verifies both PE machine types, and preserves LICENSE, NOTICE, third-party license and SPDX SBOM files. Runtime opens the staged executables without following reparse points and binds the verified digest and file identity to the Job Object-managed process. No helper is selected from `PATH` or downloaded after installation.

## Secret-safe launch contract

Bridge passes bounded non-secret configuration through argv and sends both secrets through anonymous file descriptors:

```text
run
--control-plane.tunnel-id tunnel_0123456789abcdef0123456789abcdef
--control-plane.api-key=file:/dev/fd/3
--mcp.server-url http://127.0.0.1:43210/mcp
--mcp.extra-headers "X-Codex-Bridge-Token: file:/dev/fd/4"
--health.listen-addr 127.0.0.1:0
--health.url-file /private/per-run/health.url
--pid.file /private/per-run/tunnel.pid
--allow-remote-ui=false
--open-web-ui=false
--log.level warn
--log.format json
```

Descriptor 3 receives the Runtime API Key loaded from Keychain. Descriptor 4 receives an independent 256-bit local `X-Codex-Bridge-Token`. Both descriptors are closed immediately after one bounded write. Neither secret enters argv, environment variables, YAML, SQLite, logs, IPC status, support output, or the public MCP URL.

The local MCP server binds only to `127.0.0.1` and uses the fixed `/mcp` route with constant-time header authentication. Tunnel forwards the fd-backed static header only to that configured MCP origin. ChatGPT and Tunnel never receive a local secret-bearing path URL.

The helper is spawned without a shell, with stdin replaced by `/dev/null`, inherited descriptors closed, and an explicit minimal environment. It must not inherit OpenAI API keys, admin keys, proxy credentials, MCP credentials, Codex authentication paths, or variables that can override command-line configuration. `CODEX_HOME` points to a private empty directory and `PATH` is absent.

The caller creates an app-owned runtime root with exact mode 0700. Bridge holds root and per-run directory file descriptors, binds both paths to device/inode identity, creates fixed entries with `openat`/`mkdirat`, and removes only those fixed entries. It does not recursively delete an arbitrary pathname after identity drift.

Tunnel IDs follow the upstream contract: `tunnel_` plus 32 lowercase ASCII letters or digits. Runtime Keys are preserved byte-for-byte, must be non-empty printable ASCII without leading/trailing whitespace, and are limited to 16 KiB before being stored in Keychain or sent to the helper.

## Health and readiness

Current public tunnel-client configuration exposes the health/admin server through `--health.listen-addr` and optionally writes the resolved base URL through `--health.url-file`. Bridge requests an OS-assigned loopback port with `127.0.0.1:0` and reads the resulting URL from a private regular file inside the validated per-run directory.

Before any health request, Bridge verifies that the exact supervised helper PID owns the listening TCP port using macOS `proc_pidinfo` / `proc_pidfdinfo`. The URL file must be owned by the current user, have one hard link, reject symlinks, have no group/other permissions, contain only an `http://127.0.0.1:<port>` origin, and fit the configured size bound.

Bridge connects directly to the numeric loopback address. The HTTP parser requires exactly one decimal `Content-Length`, rejects transfer encoding, caps the complete response, and accepts readiness only when `GET /readyz` returns exactly `200 ready`.

`/readyz` alone does not prove control-plane authentication. A remotely ready state additionally requires `commands_poll_last_successful_timestamp_seconds` from `/metrics` to be non-zero and fresh. The Prometheus sample value is the second whitespace-delimited field; an optional third field is a scrape timestamp and is never substituted for the poll value. With the current defaults, a successful poll older than 70 seconds is stale.

State mapping:

| Evidence | State |
|---|---|
| child spawned | `starting` |
| helper alive but no successful control-plane poll | `authenticating` |
| fresh control-plane poll but local MCP not strictly ready | `connecting` |
| fresh poll and strict local readiness | `ready` |
| previously ready, then stale poll or lost local readiness | `degraded` |
| invalid configuration, authorization failure, helper verification failure, or unexpected exit | `failed` |
| requested stop completed | `stopped` |

Tunnel failure closes only remote admission. It never cancels an already-running local Codex task. Unexpected non-action-required exits use bounded Service-level restart delays; authentication, helper identity, and invalid configuration failures require local action rather than an infinite restart loop.

## Background Service ownership

`CodexBridgeService` owns the MCP listener, Tunnel manager, Execution sessions and Supervisor sessions. The SwiftUI App controls them only through versioned local XPC calls.

- Closing or quitting the UI invalidates only the UI's XPC connection.
- MCP mode changes pause Tunnel, restart the local listener, then reconnect Tunnel with the new endpoint.
- Tunnel ID and enabled state are stored in the single Service SQLite database.
- Runtime Key and local MCP token are stored only in Keychain.
- XPC status returns Tunnel ID and health state, never either key.
- Explicit “Disable background Service” is the only UI operation that unregisters the LaunchAgent.

## Output and shutdown

Daemon stdout and stderr remain in bounded memory. Before diagnostic projection, Bridge redacts the exact Runtime Key, local MCP header secret, and compatibility secret-path URL. Raw HTTP logging is never enabled.

Requested shutdown sends `SIGTERM`, waits for the bounded process timeout, then sends `SIGKILL` and reaps the exact child PID. Bridge removes only validated per-run entries, including the URL file and pid file; cleanup never relies on the helper to remove its own runtime files.

## Automated and real acceptance

Automated tests use real fake executable processes and synthetic secrets to verify:

- suspended dynamic code identity and exact helper PID ownership;
- descriptor-only secret delivery and environment/stdin isolation;
- private dirfd and health URL-file permissions;
- strict loopback HTTP parsing and fresh control-plane poll semantics;
- bounded output redaction and authorization failure detection;
- unexpected exit, bounded restart, concurrent stop, TERM-to-KILL escalation and exact reap;
- XPC configuration without Runtime Key round-tripping;
- App UI shutdown without Service or Tunnel shutdown;
- Tunnel failure without local task cancellation.

`build-tunnel-helper.sh` reproduces the pinned v0.0.10 Universal 2 unsigned helper. `verify-tunnel-helper.sh` requires an external trusted digest and never executes its input. On Apple Silicon, `test-tunnel-helper-config.sh` separately pins the official arm64 archive and embedded helper hashes, then runs the exact official `doctor` image through the production suspended-process/CDHash boundary against the real header-authenticated Swift MCP fixture.

Final acceptance still requires the user's real Developer ID identity, a Platform-supported helper build, a restricted Runtime API Key with Tunnels Read + Use, a real Tunnel ID, and a ChatGPT Developer Mode scan/call/reconnect exercise. Those credentials are entered locally and must never be pasted into source, chat, issue reports, or logs.

Official references:

- https://github.com/openai/tunnel-client/releases/tag/v0.0.10
- https://github.com/openai/tunnel-client/blob/v0.0.10/docs/configuration.md
- https://github.com/openai/tunnel-client
- https://platform.openai.com/settings/organization/tunnels
- https://platform.openai.com/settings/organization/api-keys
