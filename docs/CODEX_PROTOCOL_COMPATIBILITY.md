# Codex app-server Compatibility

This record is version-specific. Authoritative generated schemas are committed under `Schemas/CodexAppServer/<version>/`; code must still negotiate by CLI version and tolerate unknown fields/methods.

## Verified runtime

- Codex CLI: `0.147.0-alpha.6.5`
- Verification date: 2026-08-12
- Stable schema source: `Schemas/CodexAppServer/0.147.0-alpha.6.5/stable`
- Real checks completed: process start, `initialize`/`initialized`, `model/list`.
- Real checks intentionally not yet completed: account data, Thread enumeration, task turn, steer, interrupt, approval and Supervisor.

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

## Approvals

Responses are method-specific:

- v2 command: `accept | acceptForSession | decline | cancel`, plus policy/network amendment variants;
- v2 file change: `accept | acceptForSession | decline | cancel`;
- v2 permissions: granted permission profile + `turn | session` scope; denial semantics require an isolated fixture before implementation;
- legacy exec/apply-patch: `approved`, `approved_for_session`, `denied`, `timed_out`, `abort`.

Never route these through one generic approve/deny struct. Unknown server requests default to a controlled refusal; Supervisor never approves.

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
