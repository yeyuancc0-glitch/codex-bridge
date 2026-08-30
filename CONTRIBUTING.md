# Contributing

Codex Bridge accepts focused changes that preserve its local-first architecture and fail-closed security boundaries.

## Before changing code

1. Read `README.md`, `DESIGN.md`, the public architecture documentation and the closest relevant source module.
2. Keep dependencies one-way: `App -> BridgeServiceAppShell -> BridgeIPC -> BridgeServiceHost -> application and provider modules`.
3. Do not read or commit Codex credentials, Runtime Keys, browser data, project secrets or local support bundles.
4. Preserve public API and persisted-data compatibility. Additive defaults and explicit migrations are preferred.

## Required checks

```bash
Scripts/with-xcode.sh swift build --package-path Packages/BridgeCore
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources App Service
Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO
```

Set `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` when complete Xcode is installed somewhere other than the repository's verified development location or `/Applications/Xcode.app`.

## Continuous integration

`.github/workflows/ci.yml` runs credential-free package, native Debug and architecture build checks. It uses a read-only repository token and does not load Runtime Keys, ChatGPT credentials, signing identities or notarization credentials. A green workflow does not replace release-artifact or clean-Mac acceptance.

## Pull requests

- Explain the user-visible outcome and the security/state invariant being changed.
- Include exact verification commands and results.
- Keep generated credentials, signing material, local build products and temporary fixtures out of commits.
- Do not weaken deny-by-default behavior to make a demo pass.

Security issues that may expose credentials, project data or unauthorized mutation should be reported privately as described in `SECURITY.md`.
