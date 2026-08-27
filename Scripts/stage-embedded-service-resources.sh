#!/bin/zsh
set -euo pipefail
umask 077

readonly bundle_name="BridgeCore_BridgeDeepSeekHarnessACP.bundle"
readonly requested_source="${BUILT_PRODUCTS_DIR}/${bundle_name}"
readonly source_bundle="${requested_source:A}"
readonly source_template="${source_bundle}/Contents/Resources/cordis.yml"
readonly resources_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
readonly destination_bundle="${resources_directory}/${bundle_name}"

[[ -d "${source_bundle}" && ! -L "${source_bundle}" ]] || {
  print -u2 "DeepSeek Harness resource bundle is missing or unsafe."
  exit 66
}
[[ -f "${source_template}" && ! -L "${source_template}" ]] || {
  print -u2 "DeepSeek Harness cordis template is missing or unsafe."
  exit 66
}
[[ -d "${resources_directory}" && ! -L "${resources_directory}" ]] || {
  print -u2 "App resources directory is missing or unsafe."
  exit 66
}
[[ ! -L "${destination_bundle}" ]] || {
  print -u2 "Refusing to replace a symlinked DeepSeek Harness resource bundle."
  exit 65
}

temporary_root="$(/usr/bin/mktemp -d "${TARGET_BUILD_DIR}/.codex-bridge-service-resources.XXXXXX")"
readonly temporary_root
readonly staged_bundle="${temporary_root}/${bundle_name}"

cleanup() {
  [[ -d "${temporary_root}" ]] || return
  /bin/rm -rf -- "${temporary_root}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/ditto "${source_bundle}" "${staged_bundle}"
[[ -f "${staged_bundle}/Contents/Resources/cordis.yml" ]] || {
  print -u2 "Staged DeepSeek Harness resource bundle is incomplete."
  exit 66
}

if [[ -e "${destination_bundle}" ]]; then
  /bin/rm -rf -- "${destination_bundle}"
fi
/bin/mv "${staged_bundle}" "${destination_bundle}"

print "Staged DeepSeek Harness resources for the embedded Service."
