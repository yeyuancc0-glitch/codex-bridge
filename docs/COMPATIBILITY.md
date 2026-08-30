# Compatibility Matrix

| Component | Supported baseline | Current evidence | Notes |
|---|---|---|---|
| macOS | 14 or later | package tests and native App build target macOS 14 | Release acceptance still requires clean Intel and Apple Silicon Macs. |
| Architecture | arm64 and x86_64 | release-candidate verification for separate architecture-specific App packages | Each release package contains one matching App, Service, and helper slice. The helper supply build may be Universal 2 before packaging. |
| Xcode | complete Xcode with Swift 6 support | Xcode 27 Beta 5 build `27A5237l` | Set `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` for another installation. Command Line Tools alone are insufficient. |
| Codex CLI | `app-server` protocol matching committed schemas | `0.147.0-alpha.6.5` fixtures and generated schemas | Experimental protocol; unknown or malformed fields fail closed where they affect security. |
| OpenCode | ACP v1, `1.18.20 <= version < 1.19.0` | `BridgeOpenCodeACP` probe, model catalog, Plan/Build execution, permission events and session continuation | OpenCode is installed by the user and registered explicitly in Bridge. It is not bundled. Model IDs come from ACP session config; network execution and sandboxing remain native to OpenCode. A continued session must match a terminal Bridge task in the same project and installation. |
| DeepSeek Harness | `0.1.1-rc.2`, ACP v1, Node `^22.19.0 || >=24.0.0`, pnpm `11.7.0`, ACP SDK `0.25.1` | artifact/profile validation, ACP fixture execution, dynamic model catalog, permissions, execution evidence, Web/tool/subagent composition and task control | User builds the pinned official source and registers `packages/examples/acp-demo/lib/bin.js` plus an external Bridge-matched `cordis.yml`. Bridge never reads the adjacent `.env`. Probe is not real API/Web Search acceptance. |
| Antigravity CLI | `1.1.21 <= version < 1.2.0` plus required current `--help` capabilities | `BridgeAntigravityCLI` probe, stream-json normalization, Plan/Accept Edits, native sandbox, model/effort, continuation and queued steer fixtures | User registers the real `agy` CLI, not the Desktop app. CLI authentication and permission policy remain provider-owned. Headless interactive tool approval remains an adapter boundary. |
| Swift MCP SDK | 0.12.1 | pinned in `Package.resolved`; loopback and Inspector acceptance | Production HTTP boundary is implemented by BridgeMCP because this SDK version does not provide the required listener. |
| MCP Inspector | 2.1.0 on Node 22.19+ | pinned one-shot acceptance script | Development-only; never bundled. |
| OpenAI tunnel-client | 0.0.10, commit `105e17a79a36e4e5c897fd698ed2b8dbf935b144` | pinned official archives, reproducible Universal 2 supply build, official arm64 `doctor`, loopback health ownership and helper lifecycle tests | Platform Tunnels remains the support source of truth. Unsigned preview packages ad-hoc sign the selected helper slice and record its digest; a future Developer ID release must re-sign it with the App identity before signing the App. |
| ChatGPT Developer Mode | current Secure MCP Tunnel client behavior | local helper, admission and MCP contract are covered; real account connection remains user acceptance | Bridge requires a user-provided Tunnel ID and Restricted Runtime API Key with Tunnels Read + Use. ChatGPT uses the same Tunnel ID and never receives the Runtime Key or the ChatGPT profile's local MCP Header Secret. |

## Fail-closed compatibility behavior

- Unknown Codex model or reasoning effort is never silently replaced.
- OpenCode model IDs and effort values are accepted only when returned by the current ACP session; no cross-provider aliases are synthesized.
- OpenCode Plan/Build maps to `read-only`/`workspace-write`. OpenCode network behavior remains in its native permission system; Bridge does not claim a per-task network sandbox for this provider.
- DeepSeek Harness accepts only the pinned artifact/runtime/profile contract. Model IDs come from the current ACP Session, while effort values come from the validated DSH Profile; historical Session resume is not supported.
- Antigravity accepts only a registered compatible `agy` whose observed CLI options satisfy the adapter. Plan/Accept Edits and network/tool behavior remain provider-native.
- A catalog-declared default reasoning effort is advisory UI state; missing legacy defaults fall back only to the first advertised effort, while an unknown declared default fails closed.
- Thread binding requires the exact registered working directory.
- If the background Service loses an active Codex event stream, the task becomes `unknown`; V1 does not start a replacement Turn and pretend the original resumed.
- Execution and Supervisor are independent app-server sessions. Supervisor failure degrades supervision without terminating Execution, while Supervisor approval requests are always rejected.
- Codex approvals can be allowed or denied only through the local App/XPC path; neither ChatGPT nor Supervisor receives an approval tool.
- Tunnel readiness requires exact helper-process ownership of the loopback health port, strict `/readyz`, and a fresh successful control-plane poll metric.
- tunnel-client v0.0.10 `doctor` has a documented false failure for an intentionally no-OAuth MCP endpoint returning PRMD 404. Bridge accepts only that exact structured single-failure result; any additional failed check remains fatal.
