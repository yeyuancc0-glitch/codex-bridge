# Compatibility Matrix

| Component | Supported baseline | Current evidence | Notes |
|---|---|---|---|
| macOS | 14 or later | package tests and native App build target macOS 14 | Release acceptance still requires clean Intel and Apple Silicon Macs. |
| Architecture | arm64 and x86_64 | Universal 2 build configuration and release-candidate verification | Signed Universal 2 distribution remains an external credential gate. |
| Xcode | complete Xcode with Swift 6 support | Xcode 27 Beta 5 build `27A5237l` | Set `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` for another installation. Command Line Tools alone are insufficient. |
| Codex CLI | `app-server` protocol matching committed schemas | `0.147.0-alpha.6.5` fixtures and generated schemas | Experimental protocol; unknown or malformed fields fail closed where they affect security. |
| Swift MCP SDK | 0.12.1 | pinned in `Package.resolved`; loopback and Inspector acceptance | Production HTTP boundary is implemented by BridgeMCP because this SDK version does not provide the required listener. |
| MCP Inspector | 2.1.0 on Node 22.19+ | pinned one-shot acceptance script | Development-only; never bundled. |
| OpenAI tunnel-client | 0.0.11, commit `8d55683eeef80bc5e360d95abf4692454fafc615` | pinned archive hashes, Universal 2 supply verification and helper lifecycle tests | Public release must re-sign the helper with the App's Developer ID identity before signing the App. |
| ChatGPT Developer Mode | current Secure MCP client behavior | not yet credentialed end-to-end | Requires a user-provided restricted Runtime Key and Tunnel ID. |

## Fail-closed compatibility behavior

- Unknown Codex model or reasoning effort is never silently replaced.
- A catalog-declared default reasoning effort is advisory UI state; missing legacy defaults fall back only to the first advertised effort, while an unknown declared default fails closed.
- Thread binding requires the exact registered working directory.
- Recovery uses read-only `thread/read`; an in-progress Turn without an attached event stream becomes `unknown` and keeps its locks until the user explicitly marks it suspended.
- Production Supervisor remains unavailable until each isolated HOME has a real official Codex login and the wrapped live app-server passes credentialed malicious-boundary regression; a fixture or prompt cannot open this gate.
- Codex approvals remain deny-only when command argv, permission scope or atomic file-mutation evidence is insufficient.
