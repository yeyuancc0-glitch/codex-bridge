#!/bin/zsh
set -euo pipefail
umask 077

readonly TUNNEL_CLIENT_VERSION="0.0.11"
readonly TUNNEL_CLIENT_COMMIT="8d55683eeef80bc5e360d95abf4692454fafc615"
readonly AMD64_ARCHIVE_NAME="tunnel-client-v${TUNNEL_CLIENT_VERSION}-darwin-amd64.zip"
readonly ARM64_ARCHIVE_NAME="tunnel-client-v${TUNNEL_CLIENT_VERSION}-darwin-arm64.zip"
readonly RELEASE_BASE_URL="https://github.com/openai/tunnel-client/releases/download/v${TUNNEL_CLIENT_VERSION}"
readonly AMD64_ARCHIVE_URL="${RELEASE_BASE_URL}/${AMD64_ARCHIVE_NAME}"
readonly ARM64_ARCHIVE_URL="${RELEASE_BASE_URL}/${ARM64_ARCHIVE_NAME}"
readonly AMD64_ARCHIVE_SHA256="a48c8a37983d9bf9442309cb661cd2f14d7321cfacf72375d7fa31a6a7420db0"
readonly ARM64_ARCHIVE_SHA256="3685443b057614ff932d2d477dab94be2082e60bcf4e8b4e378bebc89121b714"
readonly NOTICE_SHA256="1364c020d86ecf948b78b7c655175032068203d13aece70fb0bfe112d7802dc2"
readonly MAXIMUM_ARCHIVE_BYTES=67108864
readonly SCRIPT_DIRECTORY="${0:A:h}"
readonly NOTICE_TEXT='Copyright 2026 OpenAI

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
Distributed under the License is distributed on an “AS IS” BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
Limitations under the License.'

if (( $# != 1 )); then
  print -u2 "Usage: ${0:t} OUTPUT_DIRECTORY"
  print -u2 "OUTPUT_DIRECTORY must be an explicit path that does not already exist."
  exit 64
fi

readonly requested_output_directory="$1"
[[ -n "${requested_output_directory}" ]] || {
  print -u2 "Output directory must not be empty."
  exit 64
}
[[ ! -e "${requested_output_directory}" && ! -L "${requested_output_directory}" ]] || {
  print -u2 "Refusing to overwrite existing output path: ${requested_output_directory}"
  exit 73
}
readonly output_directory="${requested_output_directory:A}"
[[ ! -e "${output_directory}" && ! -L "${output_directory}" ]] || {
  print -u2 "Refusing resolved output path that already exists: ${output_directory}"
  exit 73
}
readonly output_parent="${output_directory:h}"
[[ -d "${output_parent}" ]] || {
  print -u2 "Output parent must be an existing directory: ${output_parent}"
  exit 72
}

temporary_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-bridge-tunnel-helper.XXXXXX")"
readonly temporary_directory
readonly amd64_archive="${temporary_directory}/${AMD64_ARCHIVE_NAME}"
readonly arm64_archive="${temporary_directory}/${ARM64_ARCHIVE_NAME}"
readonly amd64_binary="${temporary_directory}/tunnel-client-amd64"
readonly arm64_binary="${temporary_directory}/tunnel-client-arm64"
readonly universal_binary="${temporary_directory}/tunnel-client"
readonly license_file="${temporary_directory}/LICENSE"
readonly notice_file="${temporary_directory}/NOTICE"
readonly manifest_file="${temporary_directory}/tunnel-client.manifest"
output_created=0
build_succeeded=0

remove_file_if_present() {
  local path="$1"
  [[ ! -e "${path}" && ! -L "${path}" ]] || /bin/unlink "${path}"
}

cleanup() {
  remove_file_if_present "${amd64_archive}"
  remove_file_if_present "${arm64_archive}"
  remove_file_if_present "${amd64_binary}"
  remove_file_if_present "${arm64_binary}"
  remove_file_if_present "${universal_binary}"
  remove_file_if_present "${license_file}"
  remove_file_if_present "${notice_file}"
  remove_file_if_present "${manifest_file}"
  /bin/rmdir "${temporary_directory}" 2>/dev/null || true

  (( output_created == 0 || build_succeeded == 1 )) && return
  remove_file_if_present "${output_directory}/tunnel-client"
  remove_file_if_present "${output_directory}/LICENSE"
  remove_file_if_present "${output_directory}/NOTICE"
  remove_file_if_present "${output_directory}/tunnel-client.manifest"
  /bin/rmdir "${output_directory}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sha256() {
  local digest
  digest="$(/usr/bin/shasum -a 256 "$1")"
  print -r -- "${digest%% *}"
}

download_archive() {
  local url="$1"
  local destination="$2"
  /usr/bin/curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 15 \
    --max-time 180 \
    --max-filesize "${MAXIMUM_ARCHIVE_BYTES}" \
    --retry 3 \
    --retry-delay 1 \
    --output "${destination}" \
    "${url}"
}

verify_archive_hash() {
  local archive="$1"
  local expected="$2"
  local actual
  actual="$(sha256 "${archive}")"
  [[ "${actual}" == "${expected}" ]] || {
    print -u2 "Archive SHA-256 mismatch for ${archive:t}."
    return 1
  }
}

validate_archive_members() {
  local archive="$1"
  local entry listing
  local -a entries
  local -A counts
  entries=("${(@f)$(/usr/bin/unzip -Z1 "${archive}")}")
  (( ${#entries} == 4 )) || {
    print -u2 "Unexpected member count in ${archive:t}."
    return 1
  }

  for entry in "${entries[@]}"; do
    case "${entry}" in
      tunnel-client|cloudflared|cloudflared-manifest.json|LICENSE) ;;
      *)
        print -u2 "Unsafe or unexpected archive member in ${archive:t}: ${entry}"
        return 1
        ;;
    esac
    counts["${entry}"]=$(( ${counts["${entry}"]:-0} + 1 ))
  done

  for entry in tunnel-client cloudflared cloudflared-manifest.json LICENSE; do
    (( ${counts["${entry}"]:-0} == 1 )) || {
      print -u2 "Missing or duplicate archive member in ${archive:t}: ${entry}"
      return 1
    }
    listing="$(/usr/bin/zipinfo -l "${archive}" "${entry}")"
    [[ "${listing}" == -* && "${listing}" != *$'\n'* ]] || {
      print -u2 "Archive member is not one regular file in ${archive:t}: ${entry}"
      return 1
    }
  done
}

extract_regular_member() {
  local archive="$1"
  local member="$2"
  local destination="$3"
  /usr/bin/unzip -qq -p "${archive}" "${member}" > "${destination}"
  [[ -s "${destination}" ]] || {
    print -u2 "Extracted member is empty: ${member}"
    return 1
  }
}

verify_thin_architecture() {
  local binary="$1"
  local expected="$2"
  local architectures
  architectures="$(/usr/bin/lipo -archs "${binary}")"
  [[ "${architectures}" == "${expected}" ]] || {
    print -u2 "Unexpected architecture for ${binary:t}: ${architectures}"
    return 1
  }
}

verify_version_output() {
  local binary="$1"
  local output
  output="$("${binary}" --version 2>&1)"
  [[ "${output}" == "${TUNNEL_CLIENT_VERSION}+${TUNNEL_CLIENT_COMMIT} (git sha: ${TUNNEL_CLIENT_COMMIT})" ]] || {
    print -u2 "Tunnel helper version output does not match the pinned upstream build."
    return 1
  }
}

download_archive "${AMD64_ARCHIVE_URL}" "${amd64_archive}"
download_archive "${ARM64_ARCHIVE_URL}" "${arm64_archive}"
verify_archive_hash "${amd64_archive}" "${AMD64_ARCHIVE_SHA256}"
verify_archive_hash "${arm64_archive}" "${ARM64_ARCHIVE_SHA256}"
validate_archive_members "${amd64_archive}"
validate_archive_members "${arm64_archive}"

extract_regular_member "${amd64_archive}" tunnel-client "${amd64_binary}"
extract_regular_member "${arm64_archive}" tunnel-client "${arm64_binary}"
extract_regular_member "${arm64_archive}" LICENSE "${license_file}"
print -r -- "${NOTICE_TEXT}" > "${notice_file}"
[[ "$(sha256 "${notice_file}")" == "${NOTICE_SHA256}" ]] || {
  print -u2 "Embedded upstream NOTICE SHA-256 mismatch."
  exit 65
}
/bin/chmod 0755 "${amd64_binary}" "${arm64_binary}"
verify_thin_architecture "${amd64_binary}" x86_64
verify_thin_architecture "${arm64_binary}" arm64
verify_version_output "${amd64_binary}"
verify_version_output "${arm64_binary}"

/usr/bin/lipo \
  "${amd64_binary}" \
  "${arm64_binary}" \
  -create \
  -output "${universal_binary}"
/bin/chmod 0755 "${universal_binary}"
/usr/bin/lipo "${universal_binary}" -verify_arch x86_64
/usr/bin/lipo "${universal_binary}" -verify_arch arm64

readonly derived_sha256="$(sha256 "${universal_binary}")"
readonly license_sha256="$(sha256 "${license_file}")"
/bin/cat > "${manifest_file}" <<EOF
manifest.version=1
component=openai/tunnel-client
upstream.version=${TUNNEL_CLIENT_VERSION}
upstream.commit=${TUNNEL_CLIENT_COMMIT}
archive.darwin-amd64.file=${AMD64_ARCHIVE_NAME}
archive.darwin-amd64.url=${AMD64_ARCHIVE_URL}
archive.darwin-amd64.sha256=${AMD64_ARCHIVE_SHA256}
archive.darwin-arm64.file=${ARM64_ARCHIVE_NAME}
archive.darwin-arm64.url=${ARM64_ARCHIVE_URL}
archive.darwin-arm64.sha256=${ARM64_ARCHIVE_SHA256}
derived.file=tunnel-client
derived.architectures=x86_64,arm64
derived.unsigned.sha256=${derived_sha256}
license.file=LICENSE
license.sha256=${license_sha256}
notice.file=NOTICE
notice.source.commit=${TUNNEL_CLIENT_COMMIT}
notice.sha256=${NOTICE_SHA256}
EOF

/bin/mkdir -m 0700 "${output_directory}"
output_created=1
/usr/bin/install -m 0755 "${universal_binary}" "${output_directory}/tunnel-client"
/usr/bin/install -m 0644 "${license_file}" "${output_directory}/LICENSE"
/usr/bin/install -m 0644 "${notice_file}" "${output_directory}/NOTICE"
/usr/bin/install -m 0644 "${manifest_file}" "${output_directory}/tunnel-client.manifest"
/bin/zsh "${SCRIPT_DIRECTORY}/verify-tunnel-helper.sh" "${output_directory}" "${derived_sha256}"
build_succeeded=1

print "Built verified OpenAI tunnel-client v${TUNNEL_CLIENT_VERSION} Universal 2 helper in ${output_directory}."
