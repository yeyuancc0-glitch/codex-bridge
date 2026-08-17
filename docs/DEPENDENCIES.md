# Dependency Evidence

Evidence checked on 2026-08-17 against official repositories and releases. Versions are exact and `Package.resolved` is committed because the critical dependencies are pre-1.0 or infrastructure-sensitive.

| Dependency | Pin | Product | License | Project boundary | Primary evidence |
|---|---:|---|---|---|---|
| modelcontextprotocol/swift-sdk | 0.12.1 | `MCP` | mixed migration: Apache-2.0/MIT; docs CC-BY-4.0 | only `BridgeMCP`; SDK types never enter Domain | [release](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1) |
| groue/GRDB.swift | 7.11.1 | `GRDB` | MIT | only `BridgePersistence`; avoid experimental APIs | [release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1) |
| apple/swift-log | 1.15.0 | `Logging` | Apache-2.0 + NOTICE | adapter logging only; one bootstrap and central redaction | [release](https://github.com/apple/swift-log/releases/tag/1.15.0) |
| apple/swift-nio | 2.101.3 | `NIOCore`, `NIOHTTP1`, `NIOPosix` | Apache-2.0 + NOTICE | only the hardened `BridgeMCP` loopback HTTP adapter; direct dependency, never an assumed transitive product | [release](https://github.com/apple/swift-nio/releases/tag/2.101.3) |
| openai/tunnel-client | 0.0.10 | helper executable | Apache-2.0 + NOTICE | `BridgeTunnel` process boundary; not an SPM binary target | [release](https://github.com/openai/tunnel-client/releases/tag/v0.0.10) |
| @modelcontextprotocol/inspector | 2.1.0 | development CLI | MIT | test-only Streamable HTTP acceptance gate; never bundled in the App | [release](https://github.com/modelcontextprotocol/inspector/releases/tag/2.1.0) |

## Version and platform facts

- MCP 0.12.1 supports the Swift 6.1 fallback manifest and macOS 13+; the project targets Swift 6/macOS 14.
- GRDB 7.11.1 requires Swift 6.1+/Xcode 16.3+ and supports macOS 10.15+.
- swift-log 1.15.0 provides a Swift 6.1 manifest even though the default manifest uses Swift 6.2.
- swift-nio 2.101.3 supplies the listener, HTTP/1 codec and explicit write-backpressure primitives; it is pinned directly because `BridgeMCP` imports its products.
- tunnel-client v0.0.10 is the current public stable release. Its macOS release assets are separate arm64/amd64 executables, not Universal 2. The Platform Tunnels page remains the source of truth for the version supported by the control plane. The integration and secret-passing contract is recorded in [`TUNNEL_CLIENT_INTEGRATION.md`](./TUNNEL_CLIENT_INTEGRATION.md).
- MCP Inspector 2.1.0 requires Node 22.19.0+; the repository invokes that exact package version without a global installation and never passes a production Keychain secret to it.

## Tunnel helper supply-chain contract

Official v0.0.10 release evidence:

```text
commit         105e17a79a36e4e5c897fd698ed2b8dbf935b144
darwin-amd64   1a48616e584484f8bef4c1128d515ac96cf44d0d9609c1462abccc1793f4b847
darwin-arm64   288accc7fd20cfee1d495adb933773af9e19ebc0cdef3173f7fb544afa5065b2
binary-amd64    addc6fadb1ea504219e30a6ccad6dd832bf3fa1f3a4fddb6c9a39dc9b59d676a
binary-arm64    5870da52ada51e96b32375a04fa112f3c0de7238cd76e8d1ed19b06fed6acbf2
license         f4c1d7ba32ef5bcf5cf03e2eefec5825ebafedf50fa330a36700a49c605c1ef4
universal2      1f1d76a01673bd2037178c8e9c8829a6bf18ed7b3260c6fa373bf1aa66e9e371
```

Release packaging must:

1. download only the pinned archives and validate the official hashes;
2. combine both `tunnel-client` Mach-O files into a derived Universal 2 helper;
3. keep both archive hashes, thin-binary hashes, the pinned LICENSE hash and the unsigned Universal 2 hash (`1f1d76a01673bd2037178c8e9c8829a6bf18ed7b3260c6fa373bf1aa66e9e371`) in the supply record;
4. sign the helper explicitly before the main App with Developer ID and Hardened Runtime, then recompute its post-sign SHA-256 into an App-signature-covered resource used by `TunnelConfiguration`;
5. notarize and run Gatekeeper verification on the final App;
6. retain all required LICENSE/NOTICE texts.

`verify-tunnel-helper.sh` requires the trusted unsigned hash as a separate argument and performs static checks without executing its input; the manifest cannot self-attest. On Apple Silicon, `test-tunnel-helper-config.sh` separately pins both the official arm64 archive hash and its embedded linker-signed helper hash, then executes that exact image through the production suspended-process/CDHash boundary to prove official `doctor` accepts the non-secret `/mcp` URL plus fd-backed static header. These are pre-sign supply/compatibility gates, not substitutes for the final Developer ID signature and post-sign runtime hash.

Do not publish either thin release executable unchanged: the arm64 file is ad-hoc linker-signed with no Team Identifier and the final App requires a same-Team signed Universal 2 helper. The v0.0.10 platform archives contain only `tunnel-client`; no adjacent `cloudflared` binary is bundled.

## Component Decision Register note

These are infrastructure libraries, not visual primitives. UI remains entirely native SwiftUI/AppKit as recorded in `DESIGN.md`; no external UI or motion dependency is approved.
