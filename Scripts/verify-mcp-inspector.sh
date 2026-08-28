#!/bin/zsh
set -euo pipefail
umask 077

readonly MCP_INSPECTOR_VERSION="2.1.0"
readonly SCRIPT_DIRECTORY="${0:A:h}"
readonly REPOSITORY_ROOT="${SCRIPT_DIRECTORY:h}"
readonly PACKAGE_PATH="${REPOSITORY_ROOT}/Packages/BridgeCore"

temporary_directory="$(mktemp -d)"
readonly temporary_directory
readonly ready_file="${temporary_directory}/ready.json"
readonly fixture_error_file="${temporary_directory}/fixture.stderr"
readonly stop_file="${temporary_directory}/stop"
readonly initialize_file="${temporary_directory}/initialize.json"
readonly tools_file="${temporary_directory}/tools.json"
readonly status_file="${temporary_directory}/status.json"
readonly error_result_file="${temporary_directory}/error-result.json"
readonly error_diagnostic_file="${temporary_directory}/error-diagnostic.json"
readonly fresh_connection_file="${temporary_directory}/fresh-connection.json"
fixture_pid=""

wait_for_fixture_exit() {
  local maximum_attempts="$1"
  local attempt=0
  while (( attempt < maximum_attempts )); do
    ! kill -0 "${fixture_pid}" 2>/dev/null && return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

stop_fixture() {
  [[ -z "${fixture_pid}" ]] && return
  if kill -0 "${fixture_pid}" 2>/dev/null; then
    : > "${stop_file}"
    if ! wait_for_fixture_exit 100; then
      kill -TERM "${fixture_pid}" 2>/dev/null || true
      if ! wait_for_fixture_exit 40; then
        kill -KILL "${fixture_pid}" 2>/dev/null || true
      fi
    fi
  fi
  wait "${fixture_pid}" 2>/dev/null || true
  fixture_pid=""
}

cleanup() {
  stop_fixture
  rm -f -- \
    "${ready_file}" \
    "${fixture_error_file}" \
    "${stop_file}" \
    "${initialize_file}" \
    "${tools_file}" \
    "${status_file}" \
    "${error_result_file}" \
    "${error_diagnostic_file}" \
    "${fresh_connection_file}"
  rmdir "${temporary_directory}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"${REPOSITORY_ROOT}/Scripts/with-xcode.sh" swift build \
  --package-path "${PACKAGE_PATH}" \
  --product mcp-inspector-fixture

binary_directory="$(
  "${REPOSITORY_ROOT}/Scripts/with-xcode.sh" swift build \
    --package-path "${PACKAGE_PATH}" \
    --show-bin-path
)"
"${binary_directory}/mcp-inspector-fixture" \
  --stop-file "${stop_file}" \
  > "${ready_file}" \
  2> "${fixture_error_file}" &
fixture_pid=$!

for _ in {1..200}; do
  [[ -s "${ready_file}" ]] && break
  if ! kill -0 "${fixture_pid}" 2>/dev/null; then
    print -u2 "Inspector fixture exited before readiness."
    exit 1
  fi
  sleep 0.05
done
[[ -s "${ready_file}" ]] || {
  print -u2 "Inspector fixture did not become ready."
  exit 1
}

server_url="$(
  node -e \
    'const fs=require("node:fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).url)' \
    "${ready_file}"
)"

run_inspector() {
  npx --yes "@modelcontextprotocol/inspector@${MCP_INSPECTOR_VERSION}" \
    --cli \
    "${server_url}" \
    --transport http \
    --connect-timeout 5000 \
    --format json \
    "$@"
}

run_inspector --method initialize > "${initialize_file}"
run_inspector --method tools/list > "${tools_file}"
run_inspector --method tools/call --tool-name bridge_status > "${status_file}"
set +e
run_inspector \
  --method tools/call \
  --tool-name read_thread \
  --tool-args-json '{"project_id":"prj_inspector_fixture","thread_id":"missing"}' \
  > "${error_result_file}" \
  2> "${error_diagnostic_file}"
readonly tool_error_status=$?
set -e
[[ "${tool_error_status}" == 5 ]] || {
  print -u2 "Inspector did not report the expected tool error exit status."
  exit 1
}
run_inspector --method tools/call --tool-name bridge_status > "${fresh_connection_file}"

node - \
  "${initialize_file}" \
  "${tools_file}" \
  "${status_file}" \
  "${error_result_file}" \
  "${error_diagnostic_file}" \
  "${fresh_connection_file}" <<'NODE'
const fs = require("node:fs");

const read = (path) => JSON.parse(fs.readFileSync(path, "utf8"));
const unwrap = (value) => value.result ?? value;
const [initialize, tools, status, expectedError, errorDiagnostic, freshConnection] =
  process.argv.slice(2).map(read);
const initializeResult = unwrap(initialize);
const toolResult = unwrap(tools);
const statusResult = unwrap(status);
const errorResult = unwrap(expectedError);
const freshConnectionResult = unwrap(freshConnection);
if (
  initializeResult.serverInfo?.name !== "codex-bridge" ||
  !initializeResult.protocolVersion ||
  !initializeResult.capabilities?.tools
) {
  throw new Error("Inspector did not negotiate the expected server capabilities");
}
const expectedNames = [
  "bridge_status",
  "list_projects",
  "list_agents",
  "get_project",
  "search_project_files",
  "read_project_file",
  "list_threads",
  "read_thread",
  "list_models",
  "list_skills",
  "read_skill",
  "get_task",
  "get_project_changes",
  "list_project_commands",
];
const names = toolResult.tools.map((tool) => tool.name);
if (JSON.stringify(names) !== JSON.stringify(expectedNames)) {
  throw new Error(`Unexpected tool catalog: ${JSON.stringify(names)}`);
}
for (const tool of toolResult.tools) {
  if (tool.inputSchema.additionalProperties !== false || !tool.outputSchema) {
    throw new Error(`Tool schema is not strict: ${tool.name}`);
  }
  const annotations = tool.annotations;
  if (
    annotations.readOnlyHint !== true ||
    annotations.destructiveHint !== false ||
    annotations.idempotentHint !== true ||
    annotations.openWorldHint !== false
  ) {
    throw new Error(`Tool annotations are not read-only: ${tool.name}`);
  }
}

const structured = (result) => result.structuredContent;
if (
  statusResult.isError !== false ||
  structured(statusResult).mcp_state !== "ready"
) {
  throw new Error("bridge_status did not return the expected ready state");
}
const errorText = errorResult.content?.[0]?.text;
if (
  errorResult.isError !== true ||
  errorResult.structuredContent?.error?.code !== "thread_not_found" ||
  typeof errorText !== "string" ||
  JSON.stringify(JSON.parse(errorText)) !==
    JSON.stringify(errorResult.structuredContent)
) {
  throw new Error("read_thread did not preserve the structured error contract");
}
if (errorDiagnostic.error?.code !== "tool_is_error") {
  throw new Error("Inspector did not recognize the expected isError result");
}
if (
  freshConnectionResult.isError !== false ||
  structured(freshConnectionResult).mcp_state !== "ready"
) {
  throw new Error("A fresh independent Inspector connection did not succeed");
}
NODE

print "MCP Inspector ${MCP_INSPECTOR_VERSION}: initialize, tools/list, success, structured error, and fresh connection passed."
