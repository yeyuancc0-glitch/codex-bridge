#!/bin/zsh
set -euo pipefail
umask 077

readonly script_directory="${0:A:h}"
readonly repository_root="${script_directory:h}"
readonly product_version="0.1.1"
readonly artifact_base="CodexBridge-${product_version}-macos-universal2-unsigned"

if (( $# != 3 )); then
  print -u2 "Usage: ${0:t} OUTPUT_DIRECTORY HELPER_DIRECTORY TRUSTED_UNSIGNED_SHA256"
  print -u2 "Builds an unsigned local release candidate. It is not a public distribution artifact."
  exit 64
fi

readonly requested_output="$1"
readonly requested_helper_directory="$2"
readonly trusted_unsigned_sha256="$3"
[[ -n "${requested_output}" && ! -e "${requested_output}" && ! -L "${requested_output}" ]] || {
  print -u2 "Output directory must be an explicit path that does not exist."
  exit 73
}
readonly output_directory="${requested_output:A}"
readonly output_parent="${output_directory:h}"
[[ -d "${output_parent}" && ! -L "${output_parent}" ]] || {
  print -u2 "Output parent must be an existing non-symlink directory."
  exit 72
}
(( ${#trusted_unsigned_sha256} == 64 )) && \
  [[ "${trusted_unsigned_sha256}" != *[^0-9a-f]* ]] || {
  print -u2 "Trusted helper SHA-256 must be 64 lowercase hexadecimal characters."
  exit 64
}
readonly helper_directory="${requested_helper_directory:A}"

temporary_root="$(/usr/bin/mktemp -d "${output_parent}/.codex-bridge-release.XXXXXX")"
readonly temporary_root
readonly archive_path="${temporary_root}/CodexBridge.xcarchive"
readonly candidate_directory="${temporary_root}/candidate"
readonly disk_image_directory="${temporary_root}/disk-image"
readonly archived_app="${archive_path}/Products/Applications/CodexBridge.app"
readonly zip_path="${candidate_directory}/${artifact_base}.zip"
readonly dmg_path="${candidate_directory}/${artifact_base}.dmg"

cleanup() {
  [[ -d "${temporary_root}" ]] || return
  /bin/rm -rf -- "${temporary_root}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/bin/zsh "${script_directory}/verify-tunnel-helper.sh" \
  "${helper_directory}" \
  "${trusted_unsigned_sha256}"

cd "${repository_root}"
"${script_directory}/with-xcode.sh" xcodebuild \
  -project CodexBridge.xcodeproj \
  -scheme CodexBridge \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "${archive_path}" \
  archive \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  REQUIRE_TUNNEL_HELPER=YES \
  TUNNEL_HELPER_DIRECTORY="${helper_directory}" \
  TUNNEL_HELPER_UNSIGNED_SHA256="${trusted_unsigned_sha256}"

[[ -d "${archived_app}" && ! -L "${archived_app}" ]] || {
  print -u2 "Archive did not contain CodexBridge.app."
  exit 66
}
readonly app_binary="${archived_app}/Contents/MacOS/CodexBridge"
readonly bundled_helper="${archived_app}/Contents/Helpers/tunnel-client"
readonly bundled_digest="${archived_app}/Contents/Resources/TunnelClient/tunnel-client.sha256"
for binary in "${app_binary}" "${bundled_helper}"; do
  /usr/bin/lipo "${binary}" -verify_arch arm64
  /usr/bin/lipo "${binary}" -verify_arch x86_64
done
readonly actual_bundled_sha256="$(/usr/bin/shasum -a 256 "${bundled_helper}")"
readonly expected_bundled_sha256="$(/usr/bin/tr -d '[:space:]' < "${bundled_digest}")"
[[ "${actual_bundled_sha256%% *}" == "${expected_bundled_sha256}" ]] || {
  print -u2 "Bundled helper digest does not match its signed resource."
  exit 65
}

/bin/mkdir -m 0700 "${candidate_directory}" "${disk_image_directory}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${archived_app}" "${zip_path}"
/usr/bin/ditto "${archived_app}" "${disk_image_directory}/CodexBridge.app"
/bin/ln -s /Applications "${disk_image_directory}/Applications"
/usr/bin/hdiutil create \
  -quiet \
  -fs HFS+ \
  -volname "Codex Bridge" \
  -srcfolder "${disk_image_directory}" \
  "${dmg_path}"

readonly commit_epoch="$(/usr/bin/git show -s --format=%ct HEAD)"
readonly created_at="$(/bin/date -u -r "${commit_epoch}" '+%Y-%m-%dT%H:%M:%SZ')"
"${script_directory}/with-xcode.sh" xcrun swift \
  "${script_directory}/generate-sbom.swift" \
  "${repository_root}/Packages/BridgeCore/Package.resolved" \
  "${product_version}" \
  "${created_at}" \
  "${candidate_directory}/SBOM.spdx.json"

/usr/bin/install -m 0644 "${repository_root}/LICENSE" "${candidate_directory}/LICENSE"
/usr/bin/install -m 0644 "${repository_root}/NOTICE" "${candidate_directory}/NOTICE"
/usr/bin/install -m 0644 "${repository_root}/PRIVACY.md" "${candidate_directory}/PRIVACY.md"
/usr/bin/install -m 0644 \
  "${repository_root}/docs/DEPENDENCIES.md" \
  "${candidate_directory}/DEPENDENCIES.md"

{
  print -r -- "UNSIGNED LOCAL RELEASE CANDIDATE — NOT FOR PUBLIC DISTRIBUTION"
  print -r -- ""
  print -r -- "This candidate verifies Universal 2 compilation, helper staging, bundle structure, SBOM generation and packaging. It is not Developer ID signed, notarized or stapled."
} > "${candidate_directory}/RELEASE-CANDIDATE.txt"
/bin/chmod 0644 "${candidate_directory}/RELEASE-CANDIDATE.txt"

(
  cd "${candidate_directory}"
  for artifact in "${artifact_base}.dmg" "${artifact_base}.zip" SBOM.spdx.json; do
    /usr/bin/shasum -a 256 "${artifact}"
  done
) > "${candidate_directory}/SHA256SUMS"
/bin/chmod 0644 "${candidate_directory}/SHA256SUMS"

/bin/mv "${candidate_directory}" "${output_directory}"
print "Built unsigned Universal 2 release candidate at ${output_directory}"
