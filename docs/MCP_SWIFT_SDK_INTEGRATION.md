# MCP Swift SDK 0.12.1 Integration Contract

## 1. Scope and verified baseline

This document is the implementation contract for the first `BridgeMCP` target. It is based only on:

- `swift-sdk` tag `0.12.1`, commit `a0ae212ebf6eab5f754c3129608bc5557637e605`, resolved by `Packages/BridgeCore/Package.resolved`;
- the local checkout under `Packages/BridgeCore/.build/checkouts/swift-sdk`;
- the confirmed security and lifecycle requirements from the initial product design.

The checkout is build output, not a source dependency path. Production code must continue to use the exact SwiftPM package version and the `MCP` product. The paths below identify audited upstream source, not files to copy into the repository unchanged.

## 2. Decision

Use the SDK for MCP protocol messages, server lifecycle, method dispatch, initialization negotiation, cancellation notifications, and Streamable HTTP session transport. Build a small production HTTP adapter around it for loopback binding, the secret route, session ownership, resource limits, deadlines, backpressure, and shutdown.

The first real ChatGPT/Tunnel path uses `StatefulHTTPServerTransport`. It is the 0.12.1 path exercised by upstream server conformance and supports POST response SSE, GET SSE, session deletion, and `Last-Event-ID` replay. `StatelessHTTPServerTransport` remains useful for direct-JSON unit tests, but it is not the initial production default: a single `Server` actor can initialize only once, while the stateless transport has no public client/session identity with which an outer adapter can safely support reconnecting clients.

V1 does not send server-initiated progress or task-completion notifications. ChatGPT polls task tools. Stateful transport is selected for client compatibility and reconnect behavior, not as a second task event source.

## 3. Exact SDK surface

### 3.1 Server construction

Create one `MCP.Server` for each HTTP session:

```swift
let server = Server(
    name: "codex-bridge",
    version: appVersion,
    title: "Codex Bridge",
    instructions: serverInstructions,
    capabilities: .init(tools: .init(listChanged: false)),
    configuration: .strict
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: toolCatalog.definitions)
}

await server.withMethodHandler(CallTool.self) { parameters in
    try await toolDispatcher.call(parameters)
}

try await server.start(transport: transport) { clientInfo, clientCapabilities in
    await auditClientInitialization(clientInfo, clientCapabilities)
}
```

This exact API is defined in:

- `Sources/MCP/Server/Server.swift`: `Server.init`, `Server.Configuration.strict`, `withMethodHandler`, `start(transport:initializeHook:)`, `stop()`, and `currentHandlerContext`;
- `Sources/MCP/Base/Lifecycle.swift`: `Initialize` and `InitializedNotification`;
- `Sources/MCP/Base/Versioning.swift`: `Version.supported` and SDK version negotiation.

Only the tools capability is advertised initially. Do not advertise resources, prompts, logging, completions, sampling, or elicitation until Bridge implements and tests them. The SDK installs `initialize` and `ping` handlers inside `start`; Bridge must not replace them. Tool handlers should be registered before `start`.

`configuration: .strict` rejects non-initialize/non-ping requests before initialization. The SDK marks the server initialized while producing the initialize result; the HTTP session registry remains responsible for associating subsequent requests with the transport that produced that result.

### 3.2 Tool definitions and calls

The relevant protocol types are in `Sources/MCP/Server/Tools.swift`:

- `Tool(name:title:description:inputSchema:annotations:outputSchema:icons:_meta:)`;
- `Tool.Annotations`;
- `ListTools` and `ListTools.Result`;
- `CallTool.Parameters`;
- `CallTool.Result` with `content`, `structuredContent`, `isError`, and `_meta`.

Every Bridge tool definition must include:

- a JSON Schema object with `type: "object"`, explicit `properties`, `required` where applicable, and `additionalProperties: false`;
- an `outputSchema` for the stable structured result;
- read-only annotations for the phase 2 tools: `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`, and `openWorldHint: false`.

`Value` and `Value.init(_ codable:)` are defined in `Sources/MCP/Base/Value.swift`. SDK `Value` must stay inside `BridgeMCP`; application and domain services return Bridge-owned `Codable & Sendable` DTOs.

Successful tool calls return both forms:

```swift
try CallTool.Result(
    content: [.text(text: compactJSON, annotations: nil, _meta: nil)],
    structuredContent: outputDTO,
    isError: false
)
```

The compact text mirrors the structured JSON for clients that do not consume `structuredContent`. A central encoder must enforce the result limit before building both representations.

Error contract:

- malformed or unknown arguments, or an unknown tool name: throw `MCPError.invalidParams`;
- expected domain failures such as `project_not_found`, `path_denied`, `task_not_found`, `busy`, or `timeout`: return a schema-valid structured error and `isError: true`;
- unexpected internal failures: log only a redacted correlation ID and throw `MCPError.internalError` with a generic message.

Do not return absolute paths, credentials, raw internal errors, or SDK implementation details. Tool annotations are hints, not an authorization mechanism; policy checks remain in application services.

### 3.3 Streamable HTTP transport

`StatefulHTTPServerTransport` is in `Sources/MCP/Base/Transports/HTTPServer/StatefulHTTPServerTransport.swift`. Its production-use public surface is:

```swift
let transport = StatefulHTTPServerTransport(
    sessionIDGenerator: fixedGenerator,
    validationPipeline: validationPipeline,
    retryInterval: 1_000,
    logger: logger
)
try await server.start(transport: transport)
let response = await transport.handleRequest(request)
```

The SDK provides:

- a single session per transport instance;
- `MCP-Session-Id` issuance and validation;
- POST JSON-RPC ingestion and SSE responses;
- one standalone GET SSE stream per session;
- DELETE termination;
- replay from `Last-Event-ID`;
- framework-neutral `HTTPRequest` and `HTTPResponse` values;
- default Accept, Content-Type, protocol-version, session, Host, and Origin validators;
- request HTTP context through `Server.currentHandlerContext?.httpContext`.

Relevant source:

- `Sources/MCP/Base/Transports/HTTPServer/HTTPServerTypes.swift`: `SessionIDGenerator`, `HTTPRequest`, `HTTPResponse`, `HTTPHeaderName`, and `HTTPContextProviding`;
- `Sources/MCP/Base/Transports/HTTPServer/HTTPRequestValidation.swift`: `StandardValidationPipeline`, `OriginValidator`, `AcceptHeaderValidator`, `ContentTypeValidator`, `ProtocolVersionValidator`, and `SessionValidator`;
- `Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift`: direct-JSON test alternative.

Use this validation order for each production stateful transport:

```swift
StandardValidationPipeline(validators: [
    OriginValidator.localhost(port: boundPort),
    AcceptHeaderValidator(mode: .sseRequired),
    ContentTypeValidator(),
    ProtocolVersionValidator(),
    SessionValidator(),
])
```

Do not disable Origin validation. The real Tunnel regression must prove that the helper sends a loopback-compatible Host and Origin. If it does not, allow only the exact observed and documented helper values; never replace this with `OriginValidator.disabled`.

## 4. What the outer HTTP adapter must implement

The `MCP` library product does not open a listening socket. Upstream has an NIO example in `Sources/MCPConformance/Server/HTTPApp.swift`, but that file belongs to the private `MCPConformanceServer` executable target declared in `Package.swift`. `BridgeMCP` cannot import it.

The upstream example is architectural evidence for the server-per-session factory and NIO-to-`HTTPRequest` conversion only. It must not be copied as production code because it buffers request bodies without a limit, has no admission limit, writes SSE chunks without explicit writability backpressure, and relies only on an idle cleanup loop.

### 4.1 Listener and secret route

The production adapter contract is:

```text
bind address       127.0.0.1 only, never localhost/::/0.0.0.0
port               0 by default; persist the actual bound port after bind
route              /mcp/<43-character base64url 256-bit secret>
query string       rejected
other routes       empty 404 before JSON parsing
methods            POST, GET, DELETE only; 405 otherwise
TLS                 none on the loopback hop
```

The 256-bit secret is obtained from Keychain by the composition layer. The HTTP adapter receives it as an opaque value, compares the raw URL path exactly in constant time, and never logs the route, URL, query, session ID, request body, or authorization headers. Base64url without padding ensures the route has no percent-encoding ambiguity.

Route rejection occurs before allocating a request body or invoking SDK validation. `Server.currentHandlerContext` may be used for audit metadata, but it is not the primary route authorization boundary.

Use SwiftNIO for this thin adapter, following the upstream example's `NIOCore`, `NIOPosix`, and `NIOHTTP1` products. `swift-nio` is only transitive through swift-sdk today; `BridgeCore/Package.swift` must declare it directly at exact version `2.101.3` before `BridgeMCP` imports those products. Do not rely on access to a transitive package.

### 4.2 HTTP limits

The first implementation uses these hard defaults:

| Limit | Value | Enforcement owner |
|---|---:|---|
| Request target | 2 KiB | NIO HTTP decoder configuration plus request-head check |
| Aggregate headers | 32 KiB | NIO HTTP decoder configuration plus request-head check |
| Request body | 1 MiB | Reject Content-Length early and count chunked bytes; return 413 and close |
| Header/body receive time | 5 seconds each | NIO channel deadline |
| Simultaneous TCP connections | 32 | listener admission gate |
| Active MCP sessions | 4 | session registry; reject excess initialize with 503 |
| Active HTTP requests | 16 global | request admission actor; return 429 |
| Active tool calls | 8 global, 2 per session | tool admission actor; return structured `busy` |
| One complete `CallTool.Result` | 200 KiB after structured and text encoding | central result encoder; paginate before return |
| One HTTP body or SSE event | 256 KiB | response adapter; unexpected oversize terminates the session |
| Emitted response/event budget per session | 16 MiB or 512 completed calls | response adapter plus session registry; retire on next request |
| Session idle lifetime | 30 minutes | session registry |
| Session absolute lifetime | 4 hours | session registry |

These limits are configuration values with fixed production defaults, not user-controlled tool arguments. Counters must use overflow-safe integer arithmetic.

The emitted-response budget is mandatory in 0.12.1: `StatefulHTTPServerTransport` keeps `storedEvents` in an unbounded array and exposes no public trim hook. Bridge sends no unsolicited notifications in V1, counts every HTTP body/SSE event emitted for a session, and rotates the session when either budget is reached. If later features require high-volume server notifications, replace or upstream a bounded event store before enabling them.

For `.stream` responses, the NIO adapter must serialize writes, observe channel writability, stop consuming when the channel closes, and finish the stream on shutdown. It must not reproduce the upstream example's unconditional `writeAndFlush` loop.

### 4.3 Sessions and shutdown

The outer registry owns:

```swift
struct SessionContext {
    let server: Server
    let transport: StatefulHTTPServerTransport
    let createdAt: ContinuousClock.Instant
    var lastAccessedAt: ContinuousClock.Instant
}
```

Session creation rules:

1. Decode the body as public `Request<Initialize>` and also require `request.method == Initialize.name`; do not use the SDK's package-internal `JSONRPCMessageKind`.
2. Generate a random session ID and provide it through a Bridge-owned `SessionIDGenerator` implementation so the registry key and transport header are identical.
3. Construct and register all handlers on a new `Server`.
4. Start the server, insert the complete context, then pass the initialize request to `transport.handleRequest`.
5. On any error, remove the context and call `server.stop()`.

Subsequent requests use `HTTPHeaderName.sessionID` to select the exact context, update monotonic access time, and call only that transport. Unknown or retired sessions return 404. Successful DELETE removes the context after the SDK response is produced.

Shutdown and expiry call `server.stop()`, not only `transport.disconnect()`. The SDK spawns request handler tasks and does not impose tool deadlines; application service operations must be cancellation-aware and check that their session/request lease remains valid before returning. Future side-effect tools additionally rely on task idempotency and Policy Engine checks, never merely on HTTP cancellation.

## 5. Deadline contract

The SDK server dispatches concurrent `Task`s and supports client cancellation through `notifications/cancelled`, but it does not impose a handler timeout. The SDK stateful and stateless server transports also have no request-body limit, request deadline, session cap, or stored-event cap.

Each Bridge tool definition therefore has a fixed deadline:

| Tool | Deadline |
|---|---:|
| `bridge_status` | 5 seconds |
| `list_projects` | 5 seconds |
| `list_models` | 10 seconds |
| `list_threads` | 15 seconds |
| `read_thread` summary | 15 seconds |
| `read_thread` full page | 20 seconds |

The service interface accepts a `ContinuousClock.Instant` deadline and enforces it at database, process, and Codex RPC boundaries. A task-group sleep race alone is insufficient because a non-cooperative child can keep its task group alive. The MCP dispatcher performs a secondary cooperative timeout and maps expiry to a structured `timeout` result. The HTTP stream watchdog expires five seconds after the tool deadline; on breach it terminates that entire session so SDK continuations and streams cannot leak.

Long work never runs inside a single MCP request. `submit_task` will have a 5-second request deadline and return a task ID; task progress remains cursor-based polling.

## 6. First read-only tools

All list cursors are opaque, signed/validated Bridge cursors. Defaults are fixed by the server and client values above the maximum are rejected rather than silently allocating more memory.

| Tool | Input contract | Application query | Security/output rule |
|---|---|---|---|
| `bridge_status` | empty object | `statusSnapshot(deadline:)` | Versions, component health, degradations, and pending-approval count only; no usernames, paths, runtime keys, or session IDs |
| `list_projects` | `cursor?`, `limit?` (default 25, max 100) | `listMCPVisibleProjects(cursor:limit:deadline:)` | Only projects explicitly MCP-visible; return opaque `project_id`, display name, capabilities, and coarse Git state, never absolute root |
| `list_threads` | plan fields `project_id`, `cursor?`, `limit?` (default 25, max 100), `search?` (max 200 UTF-8 bytes) | `listThreads(projectID:cursor:limit:search:deadline:)` | Resolve `project_id` first; return only threads whose normalized cwd/worktree exactly belongs to that project |
| `read_thread` | `project_id`, `thread_id`, `detail` (`summary` default or `full`), `cursor?`, `limit?` (default 25, max 100) | `readThread(projectID:threadID:detail:cursor:limit:deadline:)` | Re-check project/thread binding; full content is paged so the complete dual-form MCP result stays within 200 KiB; content is untrusted data, not instructions |
| `list_models` | empty object | `listModels(deadline:)` | Return current visible model IDs, exact dynamic reasoning-effort strings, and the optional catalog-declared default effort; prefer Luna as the UI default but never invent or hardcode a Supervisor fallback |

Every output has `schema_version: 1`. Paginated outputs include `next_cursor`; terminal pages encode it as absent/null consistently. Unknown future fields are additive. Removing or changing existing field meaning requires a versioned schema/tool migration.

The BridgeMCP adapter must not call GRDB, read files, or invoke Codex processes directly. A composition-owned `BridgeMCPQueries` dependency exposes the five deadline-aware operations above and maps application DTOs to MCP DTOs. This keeps SDK types and transport state from leaking into Domain or other infrastructure adapters.

## 7. Minimal `BridgeMCP` target decomposition

```text
Sources/BridgeMCP/
├── MCPBridgeServer.swift          public start/stop façade and bound endpoint metadata
├── MCPServerFactory.swift         one strict SDK Server plus handlers per session
├── MCPToolCatalog.swift           schemas, annotations, stable names
├── MCPToolDispatcher.swift        argument decode, admission, deadline, error mapping
├── MCPToolResultEncoder.swift     structured/text result parity and byte caps
├── BridgeMCPQueries.swift         SDK-free injected query boundary and DTOs
├── ReadOnlyTools.swift            five phase-2 tool adapters
└── HTTP/
    ├── MCPHTTPListener.swift      NIO loopback bind, lifecycle, connection limits
    ├── MCPHTTPHandler.swift       head/body caps, exact route, response/backpressure
    └── MCPSessionRegistry.swift   initialize detection, server/transport ownership, expiry
```

`BridgeMCP` should depend on `BridgeDomain`, `Logging`, `MCP`, `NIOCore`, `NIOPosix`, and `NIOHTTP1`. It should not depend directly on `BridgePersistence`, `BridgeCodexRPC`, or `BridgeSecurity`; the application composition injects authorized queries. Tests may provide in-memory query implementations that verify returned data and state transitions rather than only asserting a mock invocation.

Suggested test files:

```text
Tests/BridgeMCPTests/
├── MCPServerIntegrationTests.swift
├── MCPHTTPBoundaryTests.swift
├── MCPSessionLifecycleTests.swift
├── MCPToolContractTests.swift
└── MCPConcurrencyTests.swift
```

## 8. Verification gates

### 8.1 SDK-client integration

Start BridgeMCP with an ephemeral path secret and port, then connect using the same pinned SDK's public client surface:

- `HTTPClientTransport(endpoint:configuration:streaming:sseInitializationTimeout:protocolVersion:requestModifier:logger:)` from `Sources/MCP/Base/Transports/HTTPClientTransport.swift`;
- `Client.connect(transport:)`, `listTools(cursor:)`, and the `callTool` overload returning `RequestContext<CallTool.Result>` from `Sources/MCP/Client/Client.swift`.

Use the `RequestContext` overload when asserting `structuredContent`; the convenience `callTool` overload returns only `(content, isError)` and would miss schema regressions. Set a short test `URLSessionConfiguration` timeout. Tests must cover initialize, exact tool list/schema, every first tool, structured/text parity, pagination, cancellation, reconnect, DELETE, wrong/expired session, and clean shutdown.

### 8.2 HTTP/security integration

Use real loopback sockets, not only `InMemoryTransport`, to prove:

- the listener is IPv4 `127.0.0.1` and the OS-selected port is reported correctly;
- a wrong, missing, percent-encoded, or query-bearing secret path returns empty 404 before JSON parsing;
- oversized target, headers, fixed/chunked body, concurrent requests, and sessions hit their exact limits;
- bad Host/Origin, Accept, Content-Type, protocol version, and session headers are rejected;
- SSE writes respect channel backpressure; client disconnect releases the connection/writer while a resumable session remains only until its configured expiry;
- logs and support data contain no path secret, session ID, body, authorization value, project root, or file content.

### 8.3 MCP Inspector

The internal release gate runs the official MCP Inspector CLI pinned to `2.1.0` against an ephemeral fixture endpoint. The fixture and internal acceptance script are not included in the public source snapshot.

Inspector 2.1.0 writes the complete tool result to stdout, emits a `tool_is_error` diagnostic to stderr, and exits with status 5 when a tool returns `isError: true`; the gate checks all three surfaces. The CLI is a one-shot client and exposes no deterministic MCP request-cancellation or same-session reconnect command. Separate real-loopback pinned-SDK/NIO tests prove that cancellation reaches the running query and that GET SSE resumes the same session with `Last-Event-ID`; a second CLI call proves only that a fresh connection succeeds.

Never invoke an unpinned `latest` Inspector in a release gate, and never expose the production Keychain path secret in shell history; the fixture must generate a test-only secret for every run.

### 8.4 Official conformance

Upstream evidence:

- `scripts/run-conformance.sh` builds `mcp-everything-server` and invokes `@modelcontextprotocol/conformance`;
- `.github/workflows/ci.yml` pins the action to `modelcontextprotocol/conformance@v0.1.15` and runs the server `core` suite;
- `Sources/MCPConformance/Server/main.swift` plus `HTTPApp.swift` are the tested stateful server shape;
- `conformance-baseline.yml` is upstream's expected-failure file, not Bridge's baseline.

Run the same pinned conformance release against a separately launched Bridge test server and an ephemeral URL:

```bash
npx @modelcontextprotocol/conformance@0.1.15 server \
  --url "$BRIDGE_MCP_TEST_URL" \
  --suite core
```

Do not reuse the upstream baseline. Bridge begins with no expected failures; any unavoidable, reviewed incompatibility gets a Bridge-owned baseline with a linked issue and removal condition. The SDK script itself tests the SDK example, not Bridge's listener, limits, route, or tools, so it cannot replace this gate.

Final phase-2 acceptance also requires a real MCP Inspector pass and a ChatGPT Developer Mode call through the actual Tunnel helper. Tunnel disconnect must reject new remote calls without interrupting already-running local tasks.

## 9. Known 0.12.1 risks to keep visible

1. `StatefulHTTPServerTransport.storedEvents` is unbounded and not injectable; enforce the session byte/call budget and do not enable high-volume notifications.
2. SDK `AsyncThrowingStream` instances use default unbounded buffering; Bridge caps inputs/outputs and applies admission before yielding work.
3. `Server` creates a task per request and supplies no tool deadline or concurrency limit; Bridge owns both.
4. `Server.stop()` is not a substitute for operation-level cancellation and idempotency. Service deadlines and leases remain mandatory.
5. The conformance NIO adapter is not exported from the `MCP` library and is not production hardened.
6. SwiftNIO must be a direct, pinned Bridge dependency if its products are imported, even though it is currently resolved transitively.
7. The SDK supports protocol versions `2025-11-25`, `2025-06-18`, `2025-03-26`, and `2024-11-05`. Let SDK initialization negotiate; never make tool behavior depend on an assumed single client version without a regression fixture.
8. A real Secure MCP Tunnel may expose Host/Origin behavior not represented by local SDK tests. Verify it before release without weakening loopback binding, the secret path, or DNS-rebinding protection.
