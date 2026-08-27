#!/bin/zsh
set -euo pipefail

readonly service_path="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/CodexBridgeService"
readonly deepseek_bundle="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BridgeCore_BridgeDeepSeekHarnessACP.bundle"
readonly deepseek_template="${deepseek_bundle}/Contents/Resources/cordis.yml"

[[ -f "${service_path}" && -x "${service_path}" && ! -L "${service_path}" ]] || {
  print -u2 "Embedded CodexBridgeService is missing or unsafe."
  exit 66
}
[[ -d "${deepseek_bundle}" && ! -L "${deepseek_bundle}" && \
  -f "${deepseek_template}" && ! -L "${deepseek_template}" ]] || {
  print -u2 "Embedded DeepSeek Harness resources are missing or unsafe."
  exit 66
}

for architecture in ${(z)ARCHS}; do
  /usr/bin/lipo "${service_path}" -verify_arch "${architecture}"
done

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && \
  -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && \
  "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]
then
  arguments=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime)
  if [[ "${CODE_SIGN_IDENTITY:-}" == *"Developer ID Application"* ]]; then
    arguments+=(--timestamp)
  fi
  /usr/bin/codesign "${arguments[@]}" "${service_path}"
  /usr/bin/codesign --verify --strict --verbose=2 "${service_path}"
fi

print "Verified embedded CodexBridgeService and resources for ${ARCHS}."
