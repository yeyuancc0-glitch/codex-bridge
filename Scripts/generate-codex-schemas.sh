#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_ROOT="${SCRIPT_DIR:h}"
readonly CODEX_EXECUTABLE="${1:-codex}"
readonly CODEX_VERSION="$(${CODEX_EXECUTABLE} --version | awk '{print $2}')"
readonly OUTPUT_ROOT="${PROJECT_ROOT}/Schemas/CodexAppServer/${CODEX_VERSION}"

if [[ -e "${OUTPUT_ROOT}" ]]; then
  print -u2 "Schema snapshot already exists: ${OUTPUT_ROOT}"
  exit 73
fi

mkdir -p "${OUTPUT_ROOT}/stable" "${OUTPUT_ROOT}/experimental"
"${CODEX_EXECUTABLE}" app-server generate-json-schema \
  --out "${OUTPUT_ROOT}/stable"
"${CODEX_EXECUTABLE}" app-server generate-json-schema \
  --experimental --out "${OUTPUT_ROOT}/experimental"

print "Generated Codex app-server schemas for ${CODEX_VERSION}"
