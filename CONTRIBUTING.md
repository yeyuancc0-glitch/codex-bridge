# Contributing

Codex Bridge accepts focused changes that preserve its local-first architecture and fail-closed security boundaries.

## Before changing code

1. Read `AGENTS.md`, the V2.0 implementation plan, `DESIGN.md` and the closest relevant source module.
2. Keep dependencies one-way: `AppShell -> Presentation -> Application Services -> Domain -> Infrastructure Adapters`.
3. Do not read or commit Codex credentials, Runtime Keys, browser data, project secrets or local support bundles.
4. Preserve public API and persisted-data compatibility. Additive defaults and explicit migrations are preferred.

## Required checks

```bash
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources Packages/BridgeCore/Tests UITests
Scripts/verify-mcp-inspector.sh
Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO
Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeUITests test
```

Set `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` when complete Xcode is installed somewhere other than the repository's verified development location or `/Applications/Xcode.app`.

Tests should exercise real state transitions, SQLite transactions, filesystem identities, process lifecycle or protocol fixtures. A mock-call assertion alone is not evidence for a security or recovery invariant.

## Continuous integration

`.github/workflows/ci.yml` mirrors the credential-free checks above on GitHub's ARM64 `xcode-27` runner for pull requests, pushes to `main` and manual runs. In addition to the arm64 Debug/UI checks, the workflow archives a credential-free Release app with both `arm64` and `x86_64` slices and verifies it with `lipo`. It uses a read-only repository token and does not load Runtime Keys, ChatGPT credentials, signing identities or notarization credentials. The hosted `xcode-27` image is a public preview, so a green workflow proves source, protocol and unsigned native-build compatibility on that image; it does not replace the signed release or clean-Mac acceptance in `docs/RELEASE.md`.

## Pull requests

- Explain the user-visible outcome and the security/state invariant being changed.
- Include exact verification commands and results.
- Keep generated credentials, signing material, local build products and temporary fixtures out of commits.
- Do not weaken deny-by-default behavior to make a demo pass.

Security issues that may expose credentials, project data or unauthorized mutation should be reported privately as described in `SECURITY.md`.
