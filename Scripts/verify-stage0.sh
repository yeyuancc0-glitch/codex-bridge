#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_ROOT="${SCRIPT_DIR:h}"
readonly PACKAGE_PATH="${PROJECT_ROOT}/Prototypes/AppServerProbe"

"${SCRIPT_DIR}/with-xcode.sh" swift test --package-path "${PACKAGE_PATH}"
"${SCRIPT_DIR}/with-xcode.sh" swift run \
  --package-path "${PACKAGE_PATH}" --skip-build app-server-probe-self-test
"${SCRIPT_DIR}/with-xcode.sh" swift run \
  --package-path "${PACKAGE_PATH}" --skip-build app-server-probe handshake
"${SCRIPT_DIR}/with-xcode.sh" swift run \
  --package-path "${PACKAGE_PATH}" --skip-build app-server-probe models
