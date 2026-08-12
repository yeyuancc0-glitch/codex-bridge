#!/bin/zsh
set -euo pipefail

readonly CODEX_BRIDGE_XCODE="/Volumes/fanch/Applications/Xcode-beta.app/Contents/Developer"

if [[ ! -x "${CODEX_BRIDGE_XCODE}/usr/bin/xcodebuild" ]]; then
  print -u2 "Codex Bridge: external Xcode is unavailable at ${CODEX_BRIDGE_XCODE}"
  exit 69
fi

export DEVELOPER_DIR="${CODEX_BRIDGE_XCODE}"
exec "$@"
