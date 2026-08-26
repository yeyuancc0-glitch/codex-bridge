# Release Process

v0.3.0 的公开包按开源预览方案发布：保持 Universal 2，但不配置 Apple Developer ID、不公证，也不上传签名凭据。下载者首次打开 App 时需要手动确认 Gatekeeper 提示。本文同时保留未来配置证书后的签名流程，避免把两种发布边界混在一起。

## 1. Prepare and verify the pinned helper

Use a new output directory. The script downloads only the pinned OpenAI v0.0.10 archives, verifies their external SHA-256 values, produces a Universal 2 helper and records its unsigned digest. Before every public release, recheck the OpenAI Platform Tunnels page because control-plane support may move beyond this repository pin.

```bash
helper_root="$(mktemp -d)"
Scripts/build-tunnel-helper.sh "$helper_root/tunnel"
helper_sha="$(shasum -a 256 "$helper_root/tunnel/tunnel-client" | awk '{print $1}')"
Scripts/verify-tunnel-helper.sh "$helper_root/tunnel" "$helper_sha"
```

Do not derive the trusted digest from the helper manifest inside an untrusted input directory. The separate value is part of the supply-chain boundary.

## 2. Build an unsigned local release candidate

The output path must not exist. This command archives both architectures, stages the verified helper and its post-stage digest, verifies the App and helper slices, generates an SPDX 2.3 dependency SBOM, then creates ZIP, DMG and SHA-256 files.

```bash
Scripts/build-release-candidate.sh \
  /absolute/output/CodexBridge-0.3.0-candidate \
  "$helper_root/tunnel" \
  "$helper_sha"
```

The generated files use the product version in their names and include a `RELEASE-CANDIDATE.txt` warning. v0.3.0 上传 Release 时只上传 DMG、ZIP、SBOM 和 `SHA256SUMS`；警告文件不作为下载资产上传。

OpenCode is a user-installed external runtime. The App does not bundle it; the release only contains the `BridgeOpenCodeACP` adapter and the registration/probe UI.

## 3. Optional Developer ID signing (not used for v0.3.0)

Copy `Config/Signing.xcconfig.example` to an ignored local signing configuration or provide the equivalent values from the release environment. Never commit certificate material, private keys, notary credentials or Keychain profiles.

For a future signed archive:

1. stage and sign `Contents/Helpers/tunnel-client` first with the same Developer ID Application identity and Hardened Runtime options used for the App;
2. compute `Contents/Helpers/tunnel-client.sha256` after helper signing;
3. sign the outer App through Xcode;
4. verify with `codesign --verify --deep --strict --verbose=2` and inspect the helper/App Team identifiers;
5. run `Scripts/verify-release-hardening.sh /path/to/CodexBridge.app`;
6. create ZIP and DMG from the signed App.

The Xcode helper build phase performs steps 1–2 when a real expanded signing identity is present. `REQUIRE_TUNNEL_HELPER=YES`, `TUNNEL_HELPER_DIRECTORY` and `TUNNEL_HELPER_UNSIGNED_SHA256` must be supplied for a release archive. The hardening verifier is a final-artifact gate and must run after the App, embedded Service and helper have all been signed.

## 4. Optional notarization and Gatekeeper (not used for v0.3.0)

Submit only a signed artifact using a release-owned `notarytool` Keychain profile. After success, staple the App or DMG and verify:

```bash
xcrun notarytool submit CodexBridge-0.3.0-macos.dmg \
  --keychain-profile PROFILE_NAME --wait
xcrun stapler staple CodexBridge-0.3.0-macos.dmg
xcrun stapler validate CodexBridge-0.3.0-macos.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 \
  CodexBridge-0.3.0-macos.dmg
```

Recompute published checksums after stapling. Save notary output, `codesign` verification, `spctl` results, SBOM and checksums with the release record.

## 5. Clean-machine acceptance

Test both Apple Silicon and Intel when available:

- drag-install, launch, quit and relaunch;
- three-step Service, connection and project setup plus Keychain permission behavior;
- background Service registration, App quit/relaunch and XPC reconnection without task shutdown;
- local project registration, Thread reads, read-only tools and a locally approved write task;
- bundled helper slices and Secure Tunnel connection with user-provided credentials;
- sleep/wake, Tunnel reconnect, explicit background-Service disable and uninstall;
- Gatekeeper assessment with no quarantine bypass.

For the unsigned v0.3.0 package, record the Universal 2 structure, helper digest, archive checksums, clean launch path and the user-owned ChatGPT/Tunnel acceptance separately. A local build or CI result does not claim a signed/notarized Gatekeeper result.
