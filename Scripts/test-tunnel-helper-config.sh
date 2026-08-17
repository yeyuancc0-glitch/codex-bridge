#!/bin/zsh
set -euo pipefail
umask 077

if (( $# != 0 )); then
  print -u2 "Usage: ${0:t}"
  exit 64
fi

readonly script_directory="${0:A:h}"
readonly repository_root="${script_directory:h}"
readonly helper_version="0.0.10"
readonly arm64_archive_name="tunnel-client-v${helper_version}-darwin-arm64.zip"
readonly arm64_archive_url="https://github.com/openai/tunnel-client/releases/download/v${helper_version}/${arm64_archive_name}"
readonly arm64_archive_sha256="288accc7fd20cfee1d495adb933773af9e19ebc0cdef3173f7fb544afa5065b2"
readonly arm64_helper_sha256="5870da52ada51e96b32375a04fa112f3c0de7238cd76e8d1ed19b06fed6acbf2"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || {
  print -u2 "The signed official-helper compatibility gate currently requires Apple Silicon."
  exit 69
}

temporary_directory="$(/usr/bin/mktemp -d "/tmp/cbt-tunnel.XXXXXX")"
readonly temporary_directory
readonly helper_directory="${temporary_directory}/helper"
readonly helper="${helper_directory}/tunnel-client"
readonly helper_archive="${temporary_directory}/${arm64_archive_name}"
readonly runtime_directory="${temporary_directory}/runtime"
readonly stop_file="${temporary_directory}/fixture.stop"
readonly ready_file="${temporary_directory}/fixture.json"
readonly fixture_error="${temporary_directory}/fixture.err"
fixture_pid=0

stop_process() {
  local pid="$1"
  (( pid > 0 )) || return
  /bin/kill -TERM "${pid}" 2>/dev/null || return
  for _ in {1..100}; do
    /bin/kill -0 "${pid}" 2>/dev/null || return
    /bin/sleep 0.05
  done
  /bin/kill -KILL "${pid}" 2>/dev/null || true
}

remove_file_if_present() {
  local path="$1"
  [[ ! -e "${path}" && ! -L "${path}" ]] || /bin/unlink "${path}"
}

cleanup() {
  [[ -e "${stop_file}" ]] || /usr/bin/touch "${stop_file}"
  stop_process "${fixture_pid}"
  (( fixture_pid == 0 )) || wait "${fixture_pid}" 2>/dev/null || true

  for path in \
    "${ready_file}" "${fixture_error}" "${stop_file}"; do
    remove_file_if_present "${path}"
  done
  remove_file_if_present "${helper}"
  remove_file_if_present "${helper_archive}"
  /bin/rmdir "${runtime_directory}" 2>/dev/null || true
  /bin/rmdir "${helper_directory}" 2>/dev/null || true
  /bin/rmdir "${temporary_directory}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/bin/mkdir -m 0700 "${runtime_directory}"
"${script_directory}/with-xcode.sh" swift build \
  --package-path "${repository_root}/Packages/BridgeCore" \
  --product mcp-inspector-fixture >/dev/null
"${script_directory}/with-xcode.sh" swift build \
  --package-path "${repository_root}/Packages/BridgeCore" \
  --product bridge-tunnel-acceptance-fixture >/dev/null
readonly fixture_directory="$(
  "${script_directory}/with-xcode.sh" swift build \
    --package-path "${repository_root}/Packages/BridgeCore" \
    --show-bin-path
)"
readonly fixture="${fixture_directory}/mcp-inspector-fixture"
readonly acceptance_fixture="${fixture_directory}/bridge-tunnel-acceptance-fixture"

/bin/mkdir -m 0700 "${helper_directory}"
/usr/bin/curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --proto '=https' \
  --proto-redir '=https' \
  --connect-timeout 15 \
  --max-time 180 \
  --max-filesize 67108864 \
  --retry 3 \
  --retry-delay 1 \
  --output "${helper_archive}" \
  "${arm64_archive_url}"
archive_digest="$(/usr/bin/shasum -a 256 "${helper_archive}")"
[[ "${archive_digest%% *}" == "${arm64_archive_sha256}" ]] || {
  print -u2 "Official arm64 Tunnel helper archive SHA-256 mismatch."
  exit 65
}
readonly archive_members="$(/usr/bin/unzip -Z1 "${helper_archive}")"
[[ "${archive_members}" == "tunnel-client" ]] || {
  print -u2 "Official arm64 Tunnel helper archive has unexpected members."
  exit 65
}
/usr/bin/unzip -qq -p "${helper_archive}" tunnel-client >"${helper}"
/bin/chmod 0755 "${helper}"
helper_digest="$(/usr/bin/shasum -a 256 "${helper}")"
[[ "${helper_digest%% *}" == "${arm64_helper_sha256}" ]] || {
  print -u2 "Official arm64 Tunnel helper binary SHA-256 mismatch."
  exit 65
}
/usr/bin/codesign --verify --strict --all-architectures "${helper}"

"${fixture}" \
  --stop-file "${stop_file}" \
  --authentication tunnel-header \
  >"${ready_file}" 2>"${fixture_error}" &
fixture_pid=$!

for _ in {1..100}; do
  [[ -s "${ready_file}" ]] && break
  /bin/kill -0 "${fixture_pid}" 2>/dev/null || {
    print -u2 "Tunnel-header MCP fixture exited before readiness."
    exit 1
  }
  /bin/sleep 0.05
done
[[ -s "${ready_file}" ]] || {
  print -u2 "Tunnel-header MCP fixture did not become ready."
  exit 1
}

readonly mcp_url="$(/usr/bin/plutil -extract url raw -o - "${ready_file}")"
readonly header_name="$(/usr/bin/plutil -extract header_name raw -o - "${ready_file}")"
readonly header_value="$(/usr/bin/plutil -extract header_value raw -o - "${ready_file}")"
[[ "${header_name}" == "X-Codex-Bridge-Token" ]] || {
  print -u2 "Unexpected Tunnel authentication header name."
  exit 1
}
[[ "${mcp_url}" == http://127.0.0.1:*/mcp && "${mcp_url}" != *"${header_value}"* ]] || {
  print -u2 "MCP fixture URL is not the expected non-secret loopback endpoint."
  exit 1
}

  "${acceptance_fixture}" \
  "${helper}" \
  "${arm64_helper_sha256}" \
  "${runtime_directory}" \
  "${mcp_url}" \
  "${header_value}"

print "Official signed arm64 tunnel-client doctor accepted the non-secret MCP URL and fd-backed header contract."
