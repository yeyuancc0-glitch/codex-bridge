# Codex app-server Compatibility

This record is version-specific. Authoritative generated schemas are committed under `Schemas/CodexAppServer/<version>/`; code must still negotiate by CLI version and tolerate unknown fields/methods.

## Verified runtime

- Codex CLI: `0.147.0-alpha.6.5`
- Verification date: 2026-08-12
- Stable schema source: `Schemas/CodexAppServer/0.147.0-alpha.6.5/stable`
- Real checks completed: process start, `initialize`/`initialized`, `model/list`, isolated ephemeral `thread/start`, read-only `turn/start`, `turn/steer`, `turn/interrupt`, and Luna structured-output Supervisor turn.
- Real checks intentionally not completed: account data, existing Thread enumeration, write turns, or approval decisions.
- All Thread/Turn checks used fixture-owned empty temporary directories, `approvalPolicy = never`, no network, no tools, and ephemeral Thread state. The fixture enforces a hard event timeout, validates exact outcomes, and removes its directory after every run.

## Wire envelope

The protocol is LF-delimited JSON with JSON-RPC-like envelopes, but the generated schema does not include `"jsonrpc":"2.0"`:

```json
{"id":1,"method":"initialize","params":{}}
{"method":"initialized"}
{"id":1,"result":{}}
{"id":1,"error":{"code":-32600,"message":"...","data":null}}
```

- Request IDs are `int64 | string`; Bridge emits monotonic int64 but accepts both.
- `trace` may appear on requests.
- One stdout reader owns all framing. stderr is drained separately and redacted/bounded.
- Unknown notifications are retained as audit metadata and do not crash the client.

## Initialization

Send both capability booleans explicitly:

```json
{
  "id": 1,
  "method": "initialize",
  "params": {
    "clientInfo": {
      "name": "codex_bridge_macos",
      "title": "Codex Bridge for macOS",
      "version": "0.x.y"
    },
    "capabilities": {
      "experimentalApi": false,
      "requestAttestation": false
    }
  }
}
```

The response contains `userAgent`, `codexHome`, `platformFamily`, and `platformOs`. `codexHome` is a private local path and must not enter routine logs or reports. Then send `{"method":"initialized"}` without params.

There is no method-discovery response. Capability support is derived from `codex --version`, the matching generated schema/compatibility matrix, and isolated regression tests. Do not probe support by calling account or Thread methods with real user data.

## Models

- `model/list` is cursor-paginated.
- `supportedReasoningEfforts` is an array of objects containing `reasoningEffort` and description, not an array of strings.
- Reasoning effort is an open string. UI options come only from the selected model's current response.
- Live verification returned seven visible models and confirmed `gpt-5.6-luna` supports `medium`; the app must re-read instead of persisting that as universal truth.

## Thread and Turn distinctions

- `thread/list.cwd` supports a string or string array and must use exact normalized cwd filtering.
- `thread/start.sandbox` is a kebab-case mode string such as `read-only` or `workspace-write`.
- `turn/start.sandboxPolicy` is a structured object. Workspace write requires an explicit type, writable roots, network policy, and temp-directory flags.
- Current approval policies are `untrusted`, `on-request`, `never`, or a granular object. The plan's `unlessTrusted` spelling is invalid for this version.
- Text input requires `{"type":"text","text":"...","text_elements":[]}`. Do not apply global snake-case conversion because most protocol fields are camelCase.
- `turn/steer` binds `threadId`, `expectedTurnId` and input.
- `turn/interrupt` binds `threadId` and `turnId`; user intent is not terminal state until the server confirms the turn stopped/completed.
- A successful `turn/start` response does not prove the turn is already steerable. Real verification first returned `no active turn to steer`; the correct gate is the matching `turn/started` notification before `turn/steer` or `turn/interrupt`.

## Isolated real task results

Verified on 2026-08-12 with the production `BridgeCodexRPC` adapter and `CodexRPCFixture` executable:

- basic read-only turn: default live model at its first advertised effort returned exactly `READY`, status `completed`, and exact cwd match;
- steer: after the matching `turn/started` event, same-turn steer replaced the synthetic long response with `STEERED`, status `completed`;
- interrupt: after the matching `turn/started` event, interrupt produced status `interrupted` without treating the local request as the terminal fact;
- Supervisor: the dynamically discovered Luna model accepted a JSON Schema and returned a valid `{"decision":"pass","reason":"..."}` object in read-only/no-network mode.

This Supervisor fixture proves structured-output protocol compatibility only. The current
`thread/start` and `turn/start` contracts expose no verified switch that disables core file-reading
tools. `readOnly`, no network, `approvalPolicy = never`, an empty cwd, and developer instructions do
not prove evidence-only confinement. `BridgeSupervisor.EvidenceOnlyProcessBoundary` now provides a
macOS Seatbelt profile that isolates `HOME`/`CODEX_HOME`, denies network access, `/Users`, and the
registered project root, and was verified with a malicious shell fixture that attempts both reads and
writes. `CodexSupervisorRuntime` wraps every non-fixture production session with that profile and the
desktop composition provisions a private `supervisor-home` directory. Production review remains
disabled until the real Codex login and default configuration can be supplied inside that isolated
HOME without granting denied paths, then the wrapped live app-server must pass
initialize/model/turn and credentialed end-to-end tests.

The fixture chooses the current default model and the first currently advertised reasoning effort at runtime; the Supervisor scenario searches the live catalog for Luna. These observed IDs/efforts are evidence, not persisted product defaults.

Each app-server event stream has exactly one consumer cursor. Creating multiple iterators would distribute events between consumers rather than broadcast them and can lose the matching `turn/started` or completion fact.

## Startup and wake reconciliation

- `thread/read(includeTurns: true)` returns Thread status and bounded Turn history. This version has closed Turn statuses (`completed`, `interrupted`, `failed`, `inProgress`) but no `turn/read`, active-turn attachment, event replay, `thread/subscribe`, or old-turn resume method.
- Recovery inspection runs in a fresh one-shot app-server and sends only `initialize` plus `thread/read`. Bridge requires the exact persisted Thread ID, exact registered cwd, unique bounded Turn IDs, a known Thread status, and the exact persisted Turn ID before accepting a fact.
- Exact `completed`, `interrupted`, or `failed` is authoritative enough to reduce the persisted task without starting another Turn. Root identity and current project policy are revalidated first.
- `inProgress` is accepted only when the Thread is active and that Turn is the sole in-progress Turn. This proves a read-time observation, not ownership of the original event stream. Without the original attached Runtime session, Bridge moves the task to `unknown` and retains its Thread/worktree locks.
- Recovery must never call `thread/resume` followed by `turn/start`: that starts a new generation and cannot recover the old Turn. Wake handling keeps remote submission closed until task reconciliation, durable fact refresh, and current-transport revalidation complete.

These boundaries have fake app-server process coverage. Credentialed recovery against a real existing user Thread remains a release acceptance item.

## Approvals

Responses are method-specific:

- v2 command: `accept | acceptForSession | decline | cancel`, plus policy/network amendment variants;
- v2 file change: `accept | acceptForSession | decline | cancel`;
- v2 permissions: granted permission profile + `turn | session` scope; denial semantics require an isolated fixture before implementation;
- legacy exec/apply-patch: `approved`, `approved_for_session`, `denied`, `timed_out`, `abort`.

Never route these through one generic approve/deny struct. Unknown server requests default to a controlled refusal; Supervisor never approves.

The current approval schema does not provide authoritative argv in command requests. Automatic approval must correlate `threadId + turnId + itemId/approvalId` with a persisted execution event; shell strings and best-effort `commandActions` are display evidence only. File-change item evidence can be normalized into a bounded complete manifest and bound to the registered root identity, but the app-server still applies it by pathname after Bridge responds. Because Bridge cannot make path validation and mutation one atomic operation, command, file-change and permissions approvals remain deny-only in production.

## Rate limits

`account/rateLimits/read` has no params and returns multiple buckets. `account/rateLimits/updated` can be a sparse single-bucket update keyed by `limitId`; reducers merge it into a known snapshot or re-read rather than replacing the whole catalog.

## Regression gates

Before supporting a new Codex CLI version:

1. generate stable and experimental schemas into a new version directory;
2. diff request methods and all types used by Bridge;
3. run Fake app-server framing/concurrency/approval tests;
4. run real initialize/model tests;
5. run an isolated read-only Thread/turn/steer/interrupt/Supervisor fixture with user-authorized Codex login;
6. update the compatibility matrix and only then enable write tasks.
