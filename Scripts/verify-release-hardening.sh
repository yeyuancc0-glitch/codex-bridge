#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "Usage: ${0:t} SIGNED_APP"
  exit 64
fi

readonly app="${1:A}"
readonly app_binary="${app}/Contents/MacOS/CodexBridge"
readonly service="${app}/Contents/Resources/CodexBridgeService"
readonly helper="${app}/Contents/Helpers/tunnel-client"
readonly deepseek_bundle="${app}/Contents/Resources/BridgeCore_BridgeDeepSeekHarnessACP.bundle"
readonly deepseek_template="${deepseek_bundle}/Contents/Resources/cordis.yml"

[[ -d "${app}" && ! -L "${app}" ]] || { print -u2 "App bundle is missing or unsafe."; exit 66; }
for path in "${app}" "${service}" "${helper}" "${deepseek_bundle}" "${deepseek_template}"; do
  [[ -e "${path}" && ! -L "${path}" ]] || { print -u2 "Missing release component: ${path}"; exit 66; }
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "${app}"
readonly details="$(/usr/bin/codesign -dvv "${app}" 2>&1)"
[[ "${details}" == *"TeamIdentifier="* && "${details}" != *"TeamIdentifier=not set"* ]] || {
  print -u2 "Release app has no Developer ID team identifier."; exit 65
}
[[ "${details}" == *"flags=0x10000(runtime)"* || "${details}" == *"flags=0x10000(runtime,"* ]] || {
  print -u2 "Hardened Runtime is not enabled on the release app."; exit 65
}

readonly app_team="${details##*TeamIdentifier=}"
readonly app_team_id="${app_team%%$'\n'*}"
readonly expected_architectures="$(/usr/bin/lipo -archs "${app_binary}" | /usr/bin/tr ' ' '\n' | /usr/bin/sort | /usr/bin/tr '\n' ' ')"
for component in "${service}" "${helper}"; do
  component_details="$(/usr/bin/codesign -dvv "${component}" 2>&1)"
  component_team="${component_details##*TeamIdentifier=}"
  component_team_id="${component_team%%$'\n'*}"
  [[ -n "${component_team_id}" && "${component_team_id}" == "${app_team_id}" ]] || {
    print -u2 "Component team identifier does not match the app: ${component}"; exit 65;
  }
  /usr/bin/codesign --verify --strict --verbose=2 "${component}"
  component_architectures="$(/usr/bin/lipo -archs "${component}" | /usr/bin/tr ' ' '\n' | /usr/bin/sort | /usr/bin/tr '\n' ' ')"
  [[ "${component_architectures}" == "${expected_architectures}" ]] || {
    print -u2 "Component architectures do not match the app: ${component}"
    exit 65
  }
done

print "Release hardening verified for ${app} (Team ID ${app_team_id})."
