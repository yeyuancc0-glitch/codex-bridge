# Compatibility Matrix

| Component | Supported baseline | Current evidence | Notes |
|---|---|---|---|
| macOS | 14 or later | package tests and native App build target macOS 14 | Release acceptance still requires clean Intel and Apple Silicon Macs. |
| Architecture | arm64 and x86_64 | Universal 2 build configuration and release-candidate verification | Signed Universal 2 distribution remains an external credential gate. |
| Windows | 10 version 1809 or later | hosted x64/ARM64 production closure, WinUI build, real Service IPC, EXE install/upgrade/uninstall, Portable launch, and optional MSIX build | Final UI, startup behavior, external clients and remote Tunnel acceptance require physical Windows systems. |
| Windows architecture | x64 and ARM64 | architecture-native Swift, WinUI, Tunnel helpers, fixed WebView2 runtime, EXE installers and Portable archives | 32-bit x86 is not a release target. Choose x64 for Intel/AMD PCs and ARM64 for Windows on ARM. |
| Windows distribution | unsigned per-user EXE and Portable ZIP | payload SHA-256 manifest, installed Service pipe probe, data-preserving upgrade/uninstall smoke | Hosted runners have no interactive Windows shell; the same installer smoke requires App-to-Service launch when run on an interactive system. Unsigned GitHub builds may show Unknown publisher or SmartScreen. |
| Xcode | complete Xcode with Swift 6 support | Xcode 27 Beta 5 build `27A5237l` | Set `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` for another installation. Command Line Tools alone are insufficient. |
| Codex CLI | `app-server` protocol matching committed schemas | `0.147.0-alpha.6.5` fixtures and generated schemas | Experimental protocol; unknown or malformed fields fail closed where they affect security. |
| Swift MCP SDK | 0.12.1 plus pinned Windows gates | exact fork revision in `Package.resolved`; loopback and Inspector acceptance | Fork contains only the upstream Windows import gates and the matching swift-nio pin; remove it after official releases include both fixes. |
| MCP Inspector | 2.1.0 on Node 22.19+ | pinned one-shot acceptance script | Development-only; never bundled. |
| OpenAI tunnel-client | macOS 0.0.10; Windows 0.0.12 | pinned official archives, architecture/digest verification, loopback health ownership and helper lifecycle tests | Platform Tunnels remains the support source of truth. Windows packages include the official architecture-matched helper and cloudflared payload. |
| ChatGPT Developer Mode | current Secure MCP client behavior | not yet credentialed end-to-end | Requires a user-provided restricted Runtime Key and Tunnel ID. |

## Fail-closed compatibility behavior

- Unknown Codex model or reasoning effort is never silently replaced.
- A catalog-declared default reasoning effort is advisory UI state; missing legacy defaults fall back only to the first advertised effort, while an unknown declared default fails closed.
- Thread binding requires the exact registered working directory.
- If the background Service loses an active Codex event stream, the task becomes `unknown`; V1 does not start a replacement Turn and pretend the original resumed.
- Execution and Supervisor are independent app-server sessions. Supervisor failure degrades supervision without terminating Execution, while Supervisor approval requests are always rejected.
- Codex approvals can be allowed or denied only through the local App/XPC path; neither ChatGPT nor Supervisor receives an approval tool.
- Tunnel readiness requires exact helper-process ownership of the loopback health port, strict `/readyz`, and a fresh successful control-plane poll metric.
- tunnel-client v0.0.10 `doctor` has a documented false failure for an intentionally no-OAuth MCP endpoint returning PRMD 404. Bridge accepts only that exact structured single-failure result; any additional failed check remains fatal.
- Windows Direct operations that require network denial or a transactional Git sandbox remain unavailable until a process-level Windows sandbox can enforce those boundaries; they fail closed rather than running unsandboxed.
