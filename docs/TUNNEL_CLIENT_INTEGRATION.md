# Secure MCP Tunnel Helper Integration

This contract pins the process boundary used by `BridgeTunnel`. It was verified against the official OpenAI `tunnel-client` v0.0.11 tag and release artifacts on 2026-08-12.

## Trust and packaging

- Pin v0.0.11. Validate the two official macOS archives against the SHA-256 values in `docs/DEPENDENCIES.md` before extracting either helper.
- The upstream macOS helpers are thin architecture binaries and are not Developer ID signed or notarized. The supply build combines the verified arm64 and amd64 executables and records an explicitly unsigned derived hash. Release packaging signs that Universal 2 helper, recomputes the post-sign hash into an App-signature-covered resource, then signs the containing App before notarization.
- Preserve Apache-2.0 LICENSE and NOTICE material. Do not bundle the adjacent `cloudflared` executable unless the selected production mode actually requires it.
- Runtime verification hashes an `O_NOFOLLOW` fd against that externally trusted post-sign hash. The helper is spawned suspended; Bridge resumes it and writes secrets only after the running `SecCode` passes the host Team requirement and its CDHash equals the static code identity read through the same fd. It never downloads an unverified latest release.

## Secret-safe launch contract

Bridge does not give the helper a pathname-based configuration file. All non-secret configuration is passed as bounded argv fields:

```text
--control-plane.tunnel-id tunnel_0123456789abcdef0123456789abcdef
--control-plane.api-key=file:/dev/fd/3
--mcp.server-url http://127.0.0.1:43210/mcp
--mcp.extra-headers "X-Codex-Bridge-Token: file:/dev/fd/4"
--health.unix-socket /private/per-run/tunnel-health.sock
--health.url-file /private/per-run/health-url
--pid.file /private/per-run/tunnel.pid
--allow-remote-ui=false --open-web-ui=false
--log.level warn --log.format json
```

Official v0.0.11 does **not** resolve `file:` references in an MCP server URL; using `file:/dev/fd/4` there fails validation because it has no host. Bridge therefore gives the helper a non-secret fixed `/mcp` URL. Descriptor 3 receives the Runtime Key loaded from Keychain and descriptor 4 receives the independent 256-bit `X-Codex-Bridge-Token` value supported by `mcp.extra_headers`. Both are anonymous pipes closed after one write. Neither secret enters argv, the environment, a configuration file, disk, SDK requests, or logs. The HTTP boundary checks the header in constant time and strips it before MCP SDK dispatch. Avoiding `--config` also removes the same-UID pathname replacement window that could otherwise redirect the helper after Bridge validation.

The helper is spawned without a shell, with stdin replaced by `/dev/null` and all non-declared descriptors closed. Before either pipe is written, the suspended process must pass dynamic code identity verification. Failed validation is killed and reaped without releasing the secrets.

The child receives an explicit minimal environment. It must not inherit `CONTROL_PLANE_*`, `OPENAI_API_KEY`, `OPENAI_ADMIN_KEY`, `MCP_*`, `TUNNEL_CLIENT_*`, Cloudflare tokens, proxy authorization, or header variables that could override flags or inject credentials. `CODEX_HOME` points to a private empty directory and `PATH` is absent because the Tunnel runtime does not need Codex credentials.

The caller pre-creates an app-owned root as the current user with exact mode 0700. Bridge never chmods an arbitrary configured directory. It holds root/run dirfds, binds both paths to device/inode identity, creates files with `openat`/`mkdirat`, and removes only its fixed per-run entries. Identity drift or unexpected content fails cleanup loudly rather than recursively deleting a replacement path.

Tunnel IDs follow the v0.0.11 source validator: `tunnel_` followed by 32 lowercase ASCII letters or digits. The Runtime Key is trimmed and must contain only ASCII letters, digits, `_`, or `-` before being passed to the helper. This source-derived validator is broader than the hexadecimal-only wording in one upstream documentation example.

## Health and state

The health/admin listener is a Unix-domain socket under the private runtime directory; it never binds a TCP port and never enables remote UI. Every health connection verifies `LOCAL_PEERPID` equals the exact supervised helper PID, so another same-UID process cannot impersonate readiness by replacing the socket path. The HTTP parser requires one exact decimal `Content-Length`, rejects transfer encoding and caps the complete response.

`GET /healthz` returning `200 live` means only that the process is alive. Strict local readiness requires `GET /readyz` to return exactly `200 ready`. Other 200 bodies such as an auth-required or startup-probe-timeout qualification are not accepted for this product.

`/readyz` does not prove control-plane authentication. A connected state additionally requires `commands_poll_last_successful_timestamp_seconds` from `/metrics` to be non-zero and fresh. The Prometheus sample value is the second whitespace-delimited field; an optional third field is an exporter scrape timestamp and is never used as the control-plane poll time. With the default 30-second poll and 5-second guardrail, a successful poll older than 70 seconds is stale.

State mapping:

| Evidence | State |
|---|---|
| child spawned | `starting` |
| health live, no successful poll | `authenticating` |
| fresh successful poll, local MCP not strictly ready | `connecting` |
| fresh successful poll and strict local ready | `ready` |
| previously ready, then stale poll or lost local readiness | `degraded` |
| invalid configuration, repeated authorization failure, or unexpected exit | `failed` |
| requested stop completed | `stopped` |

Control-plane network failures use the helper's built-in backoff and self-recovery; Bridge does not restart-loop it. Authorization failures may also keep the process alive, so they must be detected from bounded, redacted warnings and surfaced as action-required. Losing Tunnel connectivity blocks new remote submissions but never cancels already-running local Codex tasks.

## Output and shutdown

Daemon stdout and stderr are held in bounded memory only. Before any diagnostic projection, redact the exact Runtime Key, the local MCP header secret and the compatibility secret-path URL held by composition. Raw helper output is not included in support bundles, and `log.http_raw_unsafe` is never enabled. Authorization warnings are detected from both stdout and stderr; a 401/403 immediately prevents new remote submissions even while an older successful poll remains fresh.

Requested shutdown sends `SIGTERM`, waits at most 20 seconds, then sends `SIGKILL` and always reaps the exact child PID. Bridge then removes only its validated per-run files; a forced kill cannot rely on the helper to remove its socket or URL file.

## Acceptance boundary

Automated tests use a real fake executable process and synthetic secrets to prove suspended dynamic identity, descriptor delivery, argv/environment/stdin isolation, private dirfd permissions, cancellation and concurrent stop, stdout authorization failure, peer-PID health, strict HTTP parsing, bounded redaction, unexpected exit, TERM-to-KILL escalation and exact reap. `build-tunnel-helper.sh` reproduces the pinned Universal 2 unsigned artifact; `verify-tunnel-helper.sh` requires an external trusted hash and never executes its input. On Apple Silicon, `test-tunnel-helper-config.sh` pins both the official arm64 archive and linker-signed binary hashes, then uses the production suspended-process/CDHash boundary to run that exact official `doctor` image against the real header-authenticated Swift MCP fixture.

Final phase acceptance additionally requires the Developer ID signed helper/post-sign hash, a real restricted Runtime Key in Keychain, a real Tunnel ID and a ChatGPT Developer Mode call plus reconnect exercise. These credentials are provided by the user through the native UI and are never read from unrelated local files.

Official references: [v0.0.11 release](https://github.com/openai/tunnel-client/releases/tag/v0.0.11), [configuration](https://github.com/openai/tunnel-client/blob/8d55683eeef80bc5e360d95abf4692454fafc615/docs/configuration.md), [configuration source](https://github.com/openai/tunnel-client/blob/8d55683eeef80bc5e360d95abf4692454fafc615/pkg/config/config.go), [health source](https://github.com/openai/tunnel-client/blob/8d55683eeef80bc5e360d95abf4692454fafc615/pkg/health/health.go), and [poller source](https://github.com/openai/tunnel-client/blob/8d55683eeef80bc5e360d95abf4692454fafc615/pkg/controlplane/internal/poller.go).
