#!/bin/zsh
set -euo pipefail

readonly default_xcode="/Applications/Xcode.app/Contents/Developer"
readonly beta_xcode="/Applications/Xcode-beta.app/Contents/Developer"

if [[ -n "${CODEX_BRIDGE_XCODE_DEVELOPER_DIR:-}" ]]; then
  readonly CODEX_BRIDGE_XCODE="${CODEX_BRIDGE_XCODE_DEVELOPER_DIR}"
elif [[ -x "${default_xcode}/usr/bin/xcodebuild" ]]; then
  readonly CODEX_BRIDGE_XCODE="${default_xcode}"
else
  readonly CODEX_BRIDGE_XCODE="${beta_xcode}"
fi

if [[ ! -x "${CODEX_BRIDGE_XCODE}/usr/bin/xcodebuild" ]]; then
  print -u2 "Codex Bridge: complete Xcode is unavailable at ${CODEX_BRIDGE_XCODE}"
  print -u2 "Set CODEX_BRIDGE_XCODE_DEVELOPER_DIR to an Xcode Contents/Developer directory."
  exit 69
fi

export DEVELOPER_DIR="${CODEX_BRIDGE_XCODE}"
exec "$@"
