import Foundation
import Logging
import MCP

/// Coordinates client enablement changes with session admission.
///
/// Authentication can finish before an HTTP request reaches the session
/// registry. A generation token lets the registry reject that request after a
/// credential rotation or disablement, including while a server is starting.
public final class MCPClientAdmissionGate: @unchecked Sendable {
  public struct Token: Equatable, Sendable {
    fileprivate let generation: UInt64
  }

  private struct State {
    var enabled: Bool
    var generation: UInt64
  }

  private let lock = NSLock()
  private var states: [MCPClientID: State]

  public init(initiallyEnabled: Set<MCPClientID> = [.chatGPT]) {
    states = Dictionary(
      uniqueKeysWithValues: initiallyEnabled.map {
        ($0, State(enabled: true, generation: 1))
      }
    )
  }

  @discardableResult
  public func revoke(_ clientID: MCPClientID) -> Token {
    lock.lock()
    defer { lock.unlock() }
    let nextGeneration =
      states[clientID, default: State(enabled: false, generation: 0)]
      .generation &+ 1
    states[clientID] = State(enabled: false, generation: nextGeneration)
    return Token(generation: nextGeneration)
  }

  @discardableResult
  public func allow(_ clientID: MCPClientID) -> Token {
    lock.lock()
    defer { lock.unlock() }
    let nextGeneration =
      states[clientID, default: State(enabled: false, generation: 0)]
      .generation &+ 1
    states[clientID] = State(enabled: true, generation: nextGeneration)
    return Token(generation: nextGeneration)
  }

  public func token(for clientID: MCPClientID) -> Token? {
    lock.lock()
    defer { lock.unlock() }
    guard let state = states[clientID], state.enabled else { return nil }
    return Token(generation: state.generation)
  }

  public func isCurrent(_ token: Token, for clientID: MCPClientID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let state = states[clientID] else { return false }
    return state.enabled && state.generation == token.generation
  }

  public func isEnabled(_ clientID: MCPClientID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return states[clientID]?.enabled == true
  }
}

public actor MCPSessionRegistry {
  private static let modernProtocolVersion = "2026-07-28"

  public typealias ServerFactory = @Sendable (StatefulHTTPServerTransport) async throws -> Server
  public typealias AuthenticatedServerFactory =
    @Sendable (MCPClientID, StatefulHTTPServerTransport) async throws -> Server
  public typealias StatelessServerFactory = @Sendable () async throws -> Server
  public typealias AuthenticatedStatelessServerFactory =
    @Sendable (MCPClientID) async throws -> Server

  public struct Limits: Equatable, Sendable {
    public let maximumSessions: Int
    public let maximumSessionsPerClient: Int
    public let maximumEmittedBytes: Int
    public let maximumToolCalls: Int
    public let idleLifetime: Duration
    public let absoluteLifetime: Duration

    public init(
      maximumSessions: Int = 16,
      maximumSessionsPerClient: Int = 8,
      maximumEmittedBytes: Int = 16 * 1024 * 1024,
      maximumToolCalls: Int = 512,
      idleLifetime: Duration = .seconds(30 * 60),
      absoluteLifetime: Duration = .seconds(4 * 60 * 60)
    ) {
      self.maximumSessions = max(1, maximumSessions)
      self.maximumSessionsPerClient = max(1, min(maximumSessionsPerClient, maximumSessions))
      self.maximumEmittedBytes = max(1, maximumEmittedBytes)
      self.maximumToolCalls = max(1, maximumToolCalls)
      self.idleLifetime = idleLifetime
      self.absoluteLifetime = absoluteLifetime
    }
  }

  private struct SessionContext {
    let clientID: MCPClientID
    let admissionToken: MCPClientAdmissionGate.Token?
    let server: Server
    let transport: StatefulHTTPServerTransport
    let createdAt: ContinuousClock.Instant
    var lastAccessedAt: ContinuousClock.Instant
    var emittedBytes = 0
    var completedToolCalls = 0
    var retirementRequired = false
  }

  private struct ActiveStatelessServer {
    let clientID: MCPClientID
    let server: Server
    let requestTask: Task<HTTPResponse, Never>
  }

  private struct FixedSessionIDGenerator: SessionIDGenerator {
    let value: String

    func generateSessionID() -> String {
      value
    }
  }

  private let boundPort: Int
  private let limits: Limits
  private let serverFactory: AuthenticatedServerFactory
  private let statelessServerFactory: AuthenticatedStatelessServerFactory?
  private let clientAdmission: MCPClientAdmissionGate?
  private let clock = ContinuousClock()
  private var sessions: [String: SessionContext] = [:]
  private var activeStatelessServers: [UUID: ActiveStatelessServer] = [:]
  private var pendingSessionCreations = 0
  private var pendingSessionCreationsByClient: [MCPClientID: Int] = [:]
  private var isStopped = false

  public init(
    boundPort: Int,
    limits: Limits = .init(),
    serverFactory: @escaping ServerFactory,
    statelessServerFactory: StatelessServerFactory? = nil,
    clientAdmission: MCPClientAdmissionGate? = nil
  ) {
    self.boundPort = boundPort
    self.limits = limits
    self.serverFactory = { _, transport in try await serverFactory(transport) }
    if let statelessServerFactory {
      self.statelessServerFactory = { _ in try await statelessServerFactory() }
    } else {
      self.statelessServerFactory = nil
    }
    self.clientAdmission = clientAdmission
  }

  public init(
    boundPort: Int,
    limits: Limits = .init(),
    authenticatedServerFactory: @escaping AuthenticatedServerFactory,
    authenticatedStatelessServerFactory: AuthenticatedStatelessServerFactory? = nil,
    clientAdmission: MCPClientAdmissionGate? = nil
  ) {
    self.boundPort = boundPort
    self.limits = limits
    self.serverFactory = authenticatedServerFactory
    self.statelessServerFactory = authenticatedStatelessServerFactory
    self.clientAdmission = clientAdmission
  }

  public func handle(_ request: HTTPRequest) async -> HTTPResponse {
    await handle(AuthenticatedMCPRequest(request: request, clientID: .chatGPT))
  }

  public func handle(_ authenticatedRequest: AuthenticatedMCPRequest) async -> HTTPResponse {
    guard !isStopped else {
      return .error(statusCode: 503, .internalError("MCP service unavailable"))
    }
    await expireSessions()
    let request = authenticatedRequest.request
    let clientID = authenticatedRequest.clientID
    if let rejection = validateAuthorityAndOrigin(request, clientID: clientID) {
      return rejection
    }
    guard isClientAdmitted(clientID) else {
      return .error(statusCode: 503, .internalError("MCP client unavailable"))
    }

    if let sessionID = extractSessionID(from: request) {
      return await handleExisting(request, clientID: clientID, sessionID: sessionID)
    }
    if isDiscover(request) {
      if let rejection = validateModernRequest(request, clientID: clientID) { return rejection }
      return await handleDiscover(for: request)
    }
    if isInitialize(request) {
      return await createSession(for: request, clientID: clientID)
    }
    if isModernRequest(request) {
      return await handleModernRequest(request, clientID: clientID)
    }
    if request.body == nil || request.body?.isEmpty == true {
      return .data(Data("{}".utf8), headers: [HTTPHeaderName.contentType: "application/json"])
    }
    return .error(
      statusCode: 400,
      .invalidRequest("Bad Request: Missing MCP session identifier")
    )
  }

  private func extractSessionID(from request: HTTPRequest) -> String? {
    if let header = request.header(HTTPHeaderName.sessionID), !header.isEmpty {
      return header
    }
    if let header = request.header("session-id"), !header.isEmpty {
      return header
    }
    if let header = request.header("sessionId"), !header.isEmpty {
      return header
    }
    if let path = request.path,
      let urlComponents = URLComponents(string: path),
      let queryItems = urlComponents.queryItems
    {
      if let queryID = queryItems.first(where: {
        $0.name.caseInsensitiveCompare("sessionId") == .orderedSame
          || $0.name.caseInsensitiveCompare("session_id") == .orderedSame
      })?.value, !queryID.isEmpty {
        return queryID
      }
    }
    return nil
  }

  private func isDiscover(_ request: HTTPRequest) -> Bool {
    guard request.method.uppercased() == "POST", let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      return false
    }
    return object["method"] as? String == "server/discover"
  }

  private func isModernRequest(_ request: HTTPRequest) -> Bool {
    guard request.method.uppercased() == "POST" else { return false }
    if request.header("Mcp-Protocol-Version") != nil || request.header("Mcp-Method") != nil {
      return true
    }
    guard let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let parameters = object["params"] as? [String: Any],
      let metadata = parameters["_meta"] as? [String: Any]
    else {
      return false
    }
    return metadata["io.modelcontextprotocol/protocolVersion"] != nil
  }

  private func handleModernRequest(
    _ request: HTTPRequest,
    clientID: MCPClientID
  ) async -> HTTPResponse {
    if let rejection = validateModernRoutingHeaders(request) { return rejection }
    guard let statelessServerFactory else {
      return .error(statusCode: 400, .invalidRequest("Modern MCP requests are unavailable"))
    }
    let transport = StatelessHTTPServerTransport(
      validationPipeline: StandardValidationPipeline(validators: [
        originValidator(for: clientID),
        AcceptHeaderValidator(mode: .sseRequired),
        ContentTypeValidator(),
      ])
    )
    let admissionToken = clientAdmission?.token(for: clientID)
    var server: Server?
    do {
      let createdServer = try await statelessServerFactory(clientID)
      server = createdServer
      try await createdServer.start(transport: transport)
      guard isAdmissionCurrent(admissionToken, for: clientID) else {
        await createdServer.stop()
        return .error(statusCode: 503, .internalError("MCP client unavailable"))
      }
      let serverID = UUID()
      let requestTask = Task { await transport.handleRequest(request) }
      activeStatelessServers[serverID] = ActiveStatelessServer(
        clientID: clientID,
        server: createdServer,
        requestTask: requestTask
      )
      let response = await withTaskCancellationHandler {
        addingModernServerInfo(to: await requestTask.value)
      } onCancel: {
        requestTask.cancel()
        Task { await createdServer.stop() }
      }
      if removeStatelessServer(serverID) != nil {
        await createdServer.stop()
      }
      return response
    } catch {
      if let server {
        await server.stop()
      } else {
        await transport.disconnect()
      }
      return .error(statusCode: 500, .internalError("Modern MCP request failed"))
    }
  }

  private func validateModernRequest(
    _ request: HTTPRequest,
    clientID: MCPClientID
  ) -> HTTPResponse? {
    let pipeline = StandardValidationPipeline(validators: [
      originValidator(for: clientID),
      AcceptHeaderValidator(mode: .sseRequired),
      ContentTypeValidator(),
    ])
    if let rejection = pipeline.validate(
      request,
      context: HTTPValidationContext(
        httpMethod: request.method.uppercased(),
        isInitializationRequest: false
      )
    ) {
      return rejection
    }
    return validateModernRoutingHeaders(request)
  }

  private func validateModernRoutingHeaders(_ request: HTTPRequest) -> HTTPResponse? {
    guard let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let method = object["method"] as? String
    else {
      return .error(statusCode: 400, .invalidRequest("Bad Request: Invalid modern MCP request"))
    }
    guard let protocolVersion = request.header("Mcp-Protocol-Version") else {
      return modernHeaderMismatch("Missing MCP protocol version header")
    }
    guard protocolVersion == Self.modernProtocolVersion else {
      return .error(
        statusCode: 400,
        .serverError(
          code: -32_022,
          message: "Unsupported MCP protocol version: \(protocolVersion)"
        )
      )
    }
    guard let routedMethod = request.header("Mcp-Method"), routedMethod == method else {
      return modernHeaderMismatch("MCP method header is missing or does not match the body")
    }
    guard let parameters = object["params"] as? [String: Any],
      let metadata = parameters["_meta"] as? [String: Any],
      let bodyVersion = metadata["io.modelcontextprotocol/protocolVersion"] as? String,
      metadata["io.modelcontextprotocol/clientCapabilities"] is [String: Any]
    else {
      return .error(
        statusCode: 400,
        .invalidRequest("Bad Request: Missing modern MCP request metadata")
      )
    }
    guard bodyVersion == protocolVersion else {
      return modernHeaderMismatch("MCP protocol version header does not match the body")
    }

    guard let routedNameField = modernRoutedNameField(for: method) else {
      return nil
    }
    guard let expectedName = parameters[routedNameField] as? String,
      !expectedName.isEmpty,
      let routedName = request.header("Mcp-Name"),
      decodeModernHeaderValue(routedName) == expectedName
    else {
      return modernHeaderMismatch("MCP name header is missing or does not match the body")
    }
    return nil
  }

  private func modernRoutedNameField(for method: String) -> String? {
    switch method {
    case "tools/call", "prompts/get":
      return "name"
    case "resources/read":
      return "uri"
    default:
      return nil
    }
  }

  private func decodeModernHeaderValue(_ value: String) -> String? {
    let prefix = "=?base64?"
    let suffix = "?="
    guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return value }
    let encoded = String(value.dropFirst(prefix.count).dropLast(suffix.count))
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func modernHeaderMismatch(_ message: String) -> HTTPResponse {
    .error(statusCode: 400, .serverError(code: -32_020, message: message))
  }

  private func addingModernServerInfo(to response: HTTPResponse) -> HTTPResponse {
    guard case .data(let data, let headers) = response,
      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var result = object["result"] as? [String: Any]
    else {
      return response
    }
    var metadata = result["_meta"] as? [String: Any] ?? [:]
    metadata["io.modelcontextprotocol/serverInfo"] = [
      "name": "Codex Bridge",
      "version": "1.0.0",
    ]
    result["_meta"] = metadata
    object["result"] = result
    guard let encoded = try? JSONSerialization.data(withJSONObject: object) else { return response }
    return .data(encoded, headers: headers)
  }

  private func handleDiscover(for request: HTTPRequest) async -> HTTPResponse {
    guard let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      return .error(statusCode: 400, .invalidRequest("Bad Request: Invalid discovery request"))
    }
    let id = object["id"] ?? NSNull()
    let result: [String: Any] = [
      "resultType": "complete",
      "supportedVersions": [Self.modernProtocolVersion, Version.latest],
      "capabilities": ["tools": [:]],
      "_meta": [
        "io.modelcontextprotocol/serverInfo": [
          "name": "Codex Bridge",
          "version": "1.0.0",
        ]
      ],
      "instructions":
        "Codex Bridge exposes locally registered projects and Codex tasks. All actions are executed on the user's machine after local approval.",
    ]
    let response: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "result": result,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: response) else {
      return .error(statusCode: 500, .internalError("Discovery encoding failed"))
    }
    return .data(data, headers: [HTTPHeaderName.contentType: "application/json"])
  }

  public func recordEmittedBytes(sessionID: String?, byteCount: Int) {
    guard byteCount >= 0, let sessionID, var context = sessions[sessionID] else { return }
    let (total, overflowed) = context.emittedBytes.addingReportingOverflow(byteCount)
    context.emittedBytes = overflowed ? Int.max : total
    context.retirementRequired =
      context.retirementRequired || overflowed || total > limits.maximumEmittedBytes
    sessions[sessionID] = context
  }

  public func stop() async {
    isStopped = true
    let active = sessions.values.map(\.server)
    let activeStateless = Array(activeStatelessServers.values)
    sessions.removeAll(keepingCapacity: false)
    activeStatelessServers.removeAll(keepingCapacity: false)
    for server in active {
      await server.stop()
    }
    for active in activeStateless {
      active.requestTask.cancel()
      await active.server.stop()
    }
  }

  public func expireSessions() async {
    let now = clock.now
    let expired = sessions.compactMap { sessionID, context in
      let idle = now - context.lastAccessedAt
      let age = now - context.createdAt
      return idle >= limits.idleLifetime || age >= limits.absoluteLifetime ? sessionID : nil
    }
    for sessionID in expired {
      await closeSession(sessionID)
    }
  }

  package func terminateSession(_ sessionID: String?) async {
    guard let sessionID else { return }
    await closeSession(sessionID)
  }

  package var activeSessionCount: Int {
    sessions.count
  }

  package var activeStatelessServerCount: Int {
    activeStatelessServers.count
  }

  public func activeSessionCount(for clientID: MCPClientID) -> Int {
    sessions.values.lazy.filter { $0.clientID == clientID }.count
  }

  public func terminateSessions(for clientID: MCPClientID) async {
    let matching = sessions.compactMap { sessionID, context in
      context.clientID == clientID ? sessionID : nil
    }
    let matchingStateless = activeStatelessServers.compactMap { serverID, context in
      context.clientID == clientID ? serverID : nil
    }
    for sessionID in matching {
      await closeSession(sessionID)
    }
    for serverID in matchingStateless {
      guard let active = removeStatelessServer(serverID) else { continue }
      active.requestTask.cancel()
      await active.server.stop()
    }
  }

  private func handleExisting(
    _ request: HTTPRequest,
    clientID: MCPClientID,
    sessionID: String
  ) async -> HTTPResponse {
    guard var context = sessions[sessionID] else {
      return .error(statusCode: 404, .invalidRequest("Not Found: Session unavailable"))
    }
    guard context.clientID == clientID else {
      return .error(statusCode: 403, .invalidRequest("Forbidden: Session client mismatch"))
    }
    guard isAdmissionCurrent(context.admissionToken, for: clientID) else {
      await closeSession(sessionID)
      return .error(statusCode: 404, .invalidRequest("Not Found: Session retired"))
    }
    if context.retirementRequired || context.completedToolCalls >= limits.maximumToolCalls {
      await closeSession(sessionID)
      return .error(statusCode: 404, .invalidRequest("Not Found: Session retired"))
    }

    context.lastAccessedAt = clock.now
    sessions[sessionID] = context
    let response = await context.transport.handleRequest(request)

    if request.method.uppercased() == "DELETE", response.statusCode == 200 {
      await closeSession(sessionID)
      return response
    }
    if isToolCall(request), var current = sessions[sessionID] {
      let (count, overflowed) = current.completedToolCalls.addingReportingOverflow(1)
      current.completedToolCalls = overflowed ? Int.max : count
      current.retirementRequired = current.retirementRequired || overflowed
      sessions[sessionID] = current
    }
    return response
  }

  private func createSession(
    for request: HTTPRequest,
    clientID: MCPClientID
  ) async -> HTTPResponse {
    let admissionToken = clientAdmission?.token(for: clientID)
    guard clientAdmission == nil || admissionToken != nil else {
      return .error(statusCode: 503, .internalError("MCP client unavailable"))
    }
    let retiredServers = retireQwenSessionsForAdmission(clientID: clientID)
    let clientSessionCount = sessions.values.lazy.filter { $0.clientID == clientID }.count
    let pendingForClient = pendingSessionCreationsByClient[clientID, default: 0]
    guard !isStopped,
      sessions.count + pendingSessionCreations < limits.maximumSessions,
      clientSessionCount + pendingForClient < limits.maximumSessionsPerClient
    else {
      for server in retiredServers {
        await server.stop()
      }
      return .error(statusCode: 503, .internalError("Session capacity reached"))
    }
    pendingSessionCreations += 1
    pendingSessionCreationsByClient[clientID, default: 0] += 1
    defer {
      pendingSessionCreations -= 1
      let remaining = pendingSessionCreationsByClient[clientID, default: 1] - 1
      pendingSessionCreationsByClient[clientID] = remaining == 0 ? nil : remaining
    }
    for server in retiredServers {
      await server.stop()
    }

    let sessionID = makeUniqueSessionID()
    let validation = StandardValidationPipeline(validators: [
      originValidator(for: clientID),
      AcceptHeaderValidator(mode: .sseRequired),
      ContentTypeValidator(),
      ProtocolVersionValidator(),
      SessionValidator(),
    ])
    let transport = StatefulHTTPServerTransport(
      sessionIDGenerator: FixedSessionIDGenerator(value: sessionID),
      validationPipeline: validation,
      retryInterval: 1_000,
      logger: Logger(
        label: "codex.bridge.mcp.transport",
        factory: { _ in SwiftLogNoOpLogHandler() }
      )
    )

    var server: Server?
    do {
      let createdServer = try await serverFactory(clientID, transport)
      server = createdServer
      try await createdServer.start(transport: transport)
      guard !isStopped, isAdmissionCurrent(admissionToken, for: clientID)
      else {
        await createdServer.stop()
        return .error(statusCode: 503, .internalError("MCP service unavailable"))
      }
      let now = clock.now
      sessions[sessionID] = SessionContext(
        clientID: clientID,
        admissionToken: admissionToken,
        server: createdServer,
        transport: transport,
        createdAt: now,
        lastAccessedAt: now
      )
      let response = await transport.handleRequest(request)
      if case .error = response {
        await closeSession(sessionID)
      }
      return response
    } catch {
      if let server {
        await server.stop()
      } else {
        await transport.disconnect()
      }
      return .error(statusCode: 500, .internalError("Session unavailable"))
    }
  }

  private func retireQwenSessionsForAdmission(clientID: MCPClientID) -> [Server] {
    guard clientID == .qwenStudio else { return [] }
    var retiredServers: [Server] = []
    while sessionCapacityReached(for: clientID) {
      guard
        let oldest = sessions.lazy.filter({ $0.value.clientID == .qwenStudio }).min(by: {
          $0.value.lastAccessedAt < $1.value.lastAccessedAt
        }),
        let retired = sessions.removeValue(forKey: oldest.key)
      else {
        break
      }
      retiredServers.append(retired.server)
    }
    return retiredServers
  }

  private func sessionCapacityReached(for clientID: MCPClientID) -> Bool {
    let clientSessionCount = sessions.values.lazy.filter { $0.clientID == clientID }.count
    let pendingForClient = pendingSessionCreationsByClient[clientID, default: 0]
    return sessions.count + pendingSessionCreations >= limits.maximumSessions
      || clientSessionCount + pendingForClient >= limits.maximumSessionsPerClient
  }

  private func validateAuthorityAndOrigin(
    _ request: HTTPRequest,
    clientID: MCPClientID
  ) -> HTTPResponse? {
    originValidator(for: clientID).validate(
      request,
      context: HTTPValidationContext(
        httpMethod: request.method.uppercased(),
        isInitializationRequest: isInitialize(request)
      )
    )
  }

  private func originValidator(for clientID: MCPClientID) -> OriginValidator {
    var origins = [
      "http://127.0.0.1:\(boundPort)",
      "http://localhost:\(boundPort)",
      "http://[::1]:\(boundPort)",
    ]
    if clientID == .chatGPT {
      origins += [
        "https://chatgpt.com",
        "https://chat.openai.com",
        "https://platform.openai.com",
      ]
    }
    return OriginValidator(
      allowedHosts: [
        "127.0.0.1:\(boundPort)",
        "localhost:\(boundPort)",
        "[::1]:\(boundPort)",
      ],
      allowedOrigins: origins
    )
  }

  private func closeSession(_ sessionID: String) async {
    guard let context = sessions.removeValue(forKey: sessionID) else { return }
    await context.server.stop()
  }

  private func removeStatelessServer(_ serverID: UUID) -> ActiveStatelessServer? {
    activeStatelessServers.removeValue(forKey: serverID)
  }

  private func isAdmissionCurrent(
    _ token: MCPClientAdmissionGate.Token?,
    for clientID: MCPClientID
  ) -> Bool {
    guard let clientAdmission else { return true }
    guard let token else { return false }
    return clientAdmission.isCurrent(token, for: clientID)
  }

  private func isClientAdmitted(_ clientID: MCPClientID) -> Bool {
    guard let clientAdmission else { return true }
    return clientAdmission.isEnabled(clientID)
  }

  private func makeUniqueSessionID() -> String {
    while true {
      let candidate = UUID().uuidString.lowercased()
      if sessions[candidate] == nil {
        return candidate
      }
    }
  }

  private func isInitialize(_ request: HTTPRequest) -> Bool {
    guard request.method.uppercased() == "POST", let body = request.body else { return false }
    if let decoded = try? JSONDecoder().decode(Request<Initialize>.self, from: body),
      decoded.method == Initialize.name
    {
      return true
    }
    if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      object["method"] as? String == Initialize.name
    {
      return true
    }
    return false
  }

  private func isToolCall(_ request: HTTPRequest) -> Bool {
    guard request.method.uppercased() == "POST", let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      return false
    }
    return object["method"] as? String == CallTool.name
  }
}
