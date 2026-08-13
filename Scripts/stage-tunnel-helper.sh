#!/bin/zsh
set -euo pipefail
umask 022

readonly script_directory="${0:A:h}"
readonly helper_directory="${TUNNEL_HELPER_DIRECTORY:-}"
readonly trusted_unsigned_sha256="${TUNNEL_HELPER_UNSIGNED_SHA256:-}"
readonly require_helper="${REQUIRE_TUNNEL_HELPER:-NO}"
readonly helpers_destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
readonly resources_destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/TunnelClient"
readonly staged_helper="${helpers_destination}/tunnel-client"
readonly staged_digest="${helpers_destination}/tunnel-client.sha256"

remove_if_present() {
  local path="$1"
  [[ ! -e "${path}" && ! -L "${path}" ]] || /bin/unlink "${path}"
}

clear_staged_helper() {
  remove_if_present "${staged_helper}"
  remove_if_present "${staged_digest}"
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

readonly resolved_helper_directory="${helper_directory:A}"
/bin/zsh "${script_directory}/verify-tunnel-helper.sh" \
  "${resolved_helper_directory}" \
  "${trusted_unsigned_sha256}"

/bin/mkdir -p "${helpers_destination}" "${resources_destination}"
/bin/chmod 0755 "${helpers_destination}" "${resources_destination}"

readonly temporary_helper="${helpers_destination}/.tunnel-client.${$}"
readonly temporary_digest="${helpers_destination}/.tunnel-client.sha256.${$}"
cleanup() {
  remove_if_present "${temporary_helper}"
  remove_if_present "${temporary_digest}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/install -m 0755 "${resolved_helper_directory}/tunnel-client" "${temporary_helper}"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && \
  -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && \
  "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]
then
  sign_arguments=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime)
  if [[ "${CODE_SIGN_IDENTITY:-}" == *"Developer ID Application"* ]]; then
    sign_arguments+=(--timestamp)
  fi
  /usr/bin/codesign "${sign_arguments[@]}" "${temporary_helper}"
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

/usr/bin/lipo "${staged_helper}" -verify_arch arm64
/usr/bin/lipo "${staged_helper}" -verify_arch x86_64
print "Staged verified Universal 2 tunnel-client into ${CONTENTS_FOLDER_PATH}/Helpers."
