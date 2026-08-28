#!/bin/zsh
set -euo pipefail
umask 022

readonly script_directory="${0:A:h}"
readonly default_helper_directory="${script_directory:h}/.build/tunnel-helper"
readonly configured_helper_directory="${TUNNEL_HELPER_DIRECTORY:-}"
if [[ -n "${configured_helper_directory}" ]]; then
  helper_directory="${configured_helper_directory}"
elif [[ -d "${default_helper_directory}" ]]; then
  helper_directory="${default_helper_directory}"
else
  helper_directory=""
fi
readonly helper_directory
if [[ -n "${TUNNEL_HELPER_UNSIGNED_SHA256:-}" ]]; then
  trusted_unsigned_sha256="${TUNNEL_HELPER_UNSIGNED_SHA256}"
elif [[ "${helper_directory}" == "${default_helper_directory}" ]]; then
  trusted_unsigned_sha256="1f1d76a01673bd2037178c8e9c8829a6bf18ed7b3260c6fa373bf1aa66e9e371"
else
  trusted_unsigned_sha256=""
fi
readonly trusted_unsigned_sha256
readonly require_helper="${REQUIRE_TUNNEL_HELPER:-NO}"
readonly helper_architecture="${TUNNEL_HELPER_ARCHITECTURE:-universal}"
readonly helpers_destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
readonly resources_destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/TunnelClient"
readonly staged_helper="${helpers_destination}/tunnel-client"
readonly staged_digest="${resources_destination}/tunnel-client.sha256"
readonly legacy_staged_digest="${helpers_destination}/tunnel-client.sha256"

remove_if_present() {
  local path="$1"
  [[ ! -e "${path}" && ! -L "${path}" ]] || /bin/unlink "${path}"
}

clear_staged_helper() {
  remove_if_present "${staged_helper}"
  remove_if_present "${staged_digest}"
  remove_if_present "${legacy_staged_digest}"
  for name in LICENSE NOTICE tunnel-client.manifest; do
    remove_if_present "${resources_destination}/${name}"
  done
}

if [[ -z "${helper_directory}" || -z "${trusted_unsigned_sha256}" ]]; then
  clear_staged_helper
  if [[ "${require_helper}" == "YES" ]]; then
    print -u2 "Release build requires TUNNEL_HELPER_DIRECTORY and TUNNEL_HELPER_UNSIGNED_SHA256."
    exit 66
  fi
  print "Tunnel helper not configured; Secure Tunnel remains unavailable in this build."
  exit 0
fi

(( ${#trusted_unsigned_sha256} == 64 )) && \
  [[ "${trusted_unsigned_sha256}" != *[^0-9a-f]* ]] || {
  print -u2 "TUNNEL_HELPER_UNSIGNED_SHA256 must be 64 lowercase hexadecimal characters."
  exit 64
}
case "${helper_architecture}" in
  universal|arm64|x86_64) ;;
  *)
    print -u2 "TUNNEL_HELPER_ARCHITECTURE must be universal, arm64, or x86_64."
    exit 64
    ;;
esac

readonly resolved_helper_directory="${helper_directory:A}"
/bin/zsh "${script_directory}/verify-tunnel-helper.sh" \
  "${resolved_helper_directory}" \
  "${trusted_unsigned_sha256}"

remove_if_present "${legacy_staged_digest}"
/bin/mkdir -p "${helpers_destination}" "${resources_destination}"
/bin/chmod 0755 "${helpers_destination}" "${resources_destination}"

readonly temporary_helper="${helpers_destination}/.tunnel-client.${$}"
readonly temporary_digest="${resources_destination}/.tunnel-client.sha256.${$}"
cleanup() {
  remove_if_present "${temporary_helper}"
  remove_if_present "${temporary_digest}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${helper_architecture}" == "universal" ]]; then
  /usr/bin/install -m 0755 "${resolved_helper_directory}/tunnel-client" "${temporary_helper}"
else
  /usr/bin/lipo \
    "${resolved_helper_directory}/tunnel-client" \
    -thin "${helper_architecture}" \
    -output "${temporary_helper}"
  /bin/chmod 0755 "${temporary_helper}"
fi
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && \
  -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && \
  "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]
then
  sign_arguments=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime)
  if [[ "${CODE_SIGN_IDENTITY:-}" == *"Developer ID Application"* ]]; then
    sign_arguments+=(--timestamp)
  fi
  /usr/bin/codesign "${sign_arguments[@]}" "${temporary_helper}"
else
  /usr/bin/codesign --force --sign - "${temporary_helper}"
fi

readonly staged_sha256="$(/usr/bin/shasum -a 256 "${temporary_helper}")"
print -r -- "${staged_sha256%% *}" > "${temporary_digest}"
/bin/chmod 0644 "${temporary_digest}"
/bin/mv -f "${temporary_helper}" "${staged_helper}"
/bin/mv -f "${temporary_digest}" "${staged_digest}"

for name in LICENSE NOTICE tunnel-client.manifest; do
  /usr/bin/install -m 0644 \
    "${resolved_helper_directory}/${name}" \
    "${resources_destination}/${name}"
done

if [[ "${helper_architecture}" == "universal" ]]; then
  /usr/bin/lipo "${staged_helper}" -verify_arch arm64
  /usr/bin/lipo "${staged_helper}" -verify_arch x86_64
else
  /usr/bin/lipo "${staged_helper}" -verify_arch "${helper_architecture}"
  [[ "$(/usr/bin/lipo -archs "${staged_helper}")" == "${helper_architecture}" ]] || {
    print -u2 "Staged tunnel helper contains an unexpected architecture."
    exit 65
  }
fi
print "Staged verified ${helper_architecture} tunnel-client into ${CONTENTS_FOLDER_PATH}/Helpers."
