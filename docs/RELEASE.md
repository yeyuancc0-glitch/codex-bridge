# Release Process

Public distribution is a credentialed operation. Repository automation can build and verify an unsigned Universal 2 candidate, but it must not label that candidate as signed, notarized or safe for public distribution.

## 1. Prepare and verify the pinned helper

Use a new output directory. The script downloads only the pinned OpenAI v0.0.11 archives, verifies their external SHA-256 values, produces a Universal 2 helper and records its unsigned digest.

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
  /absolute/output/CodexBridge-0.1.0-candidate \
  "$helper_root/tunnel" \
  "$helper_sha"
```

The generated files contain `unsigned` in their names and a `RELEASE-CANDIDATE.txt` warning. They are for reproducibility and structural acceptance only.

## 3. Developer ID signing

Copy `Config/Signing.xcconfig.example` to an ignored local signing configuration or provide the equivalent values from the release environment. Never commit certificate material, private keys, notary credentials or Keychain profiles.

For the public archive:

1. stage and sign `Contents/Helpers/tunnel-client` first with the same Developer ID Application identity and Hardened Runtime options used for the App;
2. compute `Contents/Helpers/tunnel-client.sha256` after helper signing;
3. sign the outer App through Xcode;
4. verify with `codesign --verify --deep --strict --verbose=2` and inspect the helper/App Team identifiers;
5. create ZIP and DMG from the signed App.

The Xcode helper build phase performs steps 1–2 when a real expanded signing identity is present. `REQUIRE_TUNNEL_HELPER=YES`, `TUNNEL_HELPER_DIRECTORY` and `TUNNEL_HELPER_UNSIGNED_SHA256` must be supplied for a release archive.

## 4. Notarization and Gatekeeper

Submit only a signed artifact using a release-owned `notarytool` Keychain profile. After success, staple the App or DMG and verify:

```bash
xcrun notarytool submit CodexBridge-0.1.0-macos-universal2.dmg \
  --keychain-profile PROFILE_NAME --wait
xcrun stapler staple CodexBridge-0.1.0-macos-universal2.dmg
xcrun stapler validate CodexBridge-0.1.0-macos-universal2.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 \
  CodexBridge-0.1.0-macos-universal2.dmg
```

Recompute published checksums after stapling. Save notary output, `codesign` verification, `spctl` results, SBOM and checksums with the release record.

## 5. Clean-machine acceptance

Test both Apple Silicon and Intel when available:

- drag-install, launch, quit and relaunch;
- nine-step onboarding and Keychain permission behavior;
- local-only project registration and read-only task;
- signed helper identity and Secure Tunnel connection with user-provided credentials;
- sleep/wake, notification deep link, recovery and uninstall;
- Gatekeeper assessment with no quarantine bypass.

No public release is complete until these checks and the credentialed ChatGPT/Tunnel flow pass.
