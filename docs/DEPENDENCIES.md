# Dependency Evidence

Evidence checked on 2026-08-12 against official repositories and releases. Versions are exact and `Package.resolved` is committed because all five critical dependencies are pre-1.0 or infrastructure-sensitive.

| Dependency | Pin | Product | License | Project boundary | Primary evidence |
|---|---:|---|---|---|---|
| modelcontextprotocol/swift-sdk | 0.12.1 | `MCP` | mixed migration: Apache-2.0/MIT; docs CC-BY-4.0 | only `BridgeMCP`; SDK types never enter Domain | [release](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1) |
| groue/GRDB.swift | 7.11.1 | `GRDB` | MIT | only `BridgePersistence`; avoid experimental APIs | [release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1) |
| apple/swift-log | 1.15.0 | `Logging` | Apache-2.0 + NOTICE | adapter logging only; one bootstrap and central redaction | [release](https://github.com/apple/swift-log/releases/tag/1.15.0) |
| apple/swift-nio | 2.101.3 | `NIOCore`, `NIOHTTP1`, `NIOPosix` | Apache-2.0 + NOTICE | only the hardened `BridgeMCP` loopback HTTP adapter; direct dependency, never an assumed transitive product | [release](https://github.com/apple/swift-nio/releases/tag/2.101.3) |
| openai/tunnel-client | 0.0.11 | helper executable | Apache-2.0 + NOTICE | `BridgeTunnel` process boundary; not an SPM binary target | [release](https://github.com/openai/tunnel-client/releases/tag/v0.0.11) |
| @modelcontextprotocol/inspector | 2.1.0 | development CLI | MIT | test-only Streamable HTTP acceptance gate; never bundled in the App | [release](https://github.com/modelcontextprotocol/inspector/releases/tag/2.1.0) |

## Version and platform facts

- MCP 0.12.1 supports the Swift 6.1 fallback manifest and macOS 13+; the project targets Swift 6/macOS 14.
- GRDB 7.11.1 requires Swift 6.1+/Xcode 16.3+ and supports macOS 10.15+.
- swift-log 1.15.0 provides a Swift 6.1 manifest even though the default manifest uses Swift 6.2.
- swift-nio 2.101.3 supplies the listener, HTTP/1 codec and explicit write-backpressure primitives; it is pinned directly because `BridgeMCP` imports its products.
- tunnel-client v0.0.11 is built with Go 1.26.2. Its macOS artifacts target macOS 12+ and are separate arm64/amd64 executables, not Universal 2. The integration and secret-passing contract is recorded in [`TUNNEL_CLIENT_INTEGRATION.md`](./TUNNEL_CLIENT_INTEGRATION.md).
- MCP Inspector 2.1.0 requires Node 22.19.0+; the repository invokes that exact package version without a global installation and never passes a production Keychain secret to it.

## Tunnel helper supply-chain contract

Official v0.0.11 archive SHA-256 values:

```text
darwin-amd64 a48c8a37983d9bf9442309cb661cd2f14d7321cfacf72375d7fa31a6a7420db0
darwin-arm64 3685443b057614ff932d2d477dab94be2082e60bcf4e8b4e378bebc89121b714
```

Release packaging must:

1. download only the pinned archives and validate the official hashes;
2. combine both `tunnel-client` Mach-O files into a derived Universal 2 helper;
3. keep source archive hashes and the unsigned Universal 2 hash in the supply manifest (`bd0a2caf0d3047f10a08f2422f7d07db03ab55e3c58c72575b1cbf684d60475d` for the pinned inputs);
4. sign the helper explicitly before the main App with Developer ID and Hardened Runtime, then recompute its post-sign SHA-256 into an App-signature-covered resource used by `TunnelConfiguration`;
5. notarize and run Gatekeeper verification on the final App;
6. retain all required LICENSE/NOTICE texts.

`verify-tunnel-helper.sh` requires the trusted unsigned hash as a separate argument and performs static checks without executing its input; the manifest cannot self-attest. On Apple Silicon, `test-tunnel-helper-config.sh` separately pins both the official arm64 archive hash and its embedded linker-signed helper hash, then executes that exact image through the production suspended-process/CDHash boundary to prove official `doctor` accepts the non-secret `/mcp` URL plus fd-backed static header. These are pre-sign supply/compatibility gates, not substitutes for the final Developer ID signature and post-sign runtime hash.

Do not publish the release archive binary unchanged: arm64 is only ad-hoc signed and amd64 is unsigned. Only include the pinned `cloudflared 2026.7.2` companion when the selected deployment mode needs it; ordinary OpenAI control-plane operation should not expand the bundle without evidence.

## Component Decision Register note

These are infrastructure libraries, not visual primitives. UI remains entirely native SwiftUI/AppKit as recorded in `DESIGN.md`; no external UI or motion dependency is approved.
