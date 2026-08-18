import Foundation
import Logging
import MCP

public actor MCPSessionRegistry {
  public typealias ServerFactory = @Sendable (StatefulHTTPServerTransport) async throws -> Server
  public typealias StatelessServerFactory = @Sendable () async throws -> Server

  public struct Limits: Equatable, Sendable {
    public let maximumSessions: Int
    public let maximumEmittedBytes: Int
    public let maximumToolCalls: Int
    public let idleLifetime: Duration
    public let absoluteLifetime: Duration

    public init(
      maximumSessions: Int = 4,
      maximumEmittedBytes: Int = 16 * 1024 * 1024,
      maximumToolCalls: Int = 512,
      idleLifetime: Duration = .seconds(30 * 60),
      absoluteLifetime: Duration = .seconds(4 * 60 * 60)
    ) {
      self.maximumSessions = max(1, maximumSessions)
      self.maximumEmittedBytes = max(1, maximumEmittedBytes)
      self.maximumToolCalls = max(1, maximumToolCalls)
      self.idleLifetime = idleLifetime
      self.absoluteLifetime = absoluteLifetime
    }
  }

  private struct SessionContext {
    let server: Server
    let transport: StatefulHTTPServerTransport
    let createdAt: ContinuousClock.Instant
    var lastAccessedAt: ContinuousClock.Instant
    var emittedBytes = 0
    var completedToolCalls = 0
    var retirementRequired = false
  }

  private struct FixedSessionIDGenerator: SessionIDGenerator {
    let value: String

    func generateSessionID() -> String {
      value
    }
  }

  private let boundPort: Int
  private let limits: Limits
  private let serverFactory: ServerFactory
  private let statelessServerFactory: StatelessServerFactory?
  private let clock = ContinuousClock()
  private var sessions: [String: SessionContext] = [:]
  private var pendingSessionCreations = 0
  private var isStopped = false

  public init(
    boundPort: Int,
    limits: Limits = .init(),
    serverFactory: @escaping ServerFactory,
    statelessServerFactory: StatelessServerFactory? = nil
  ) {
    self.boundPort = boundPort
    self.limits = limits
    self.serverFactory = serverFactory
    self.statelessServerFactory = statelessServerFactory
  }

  public func handle(_ request: HTTPRequest) async -> HTTPResponse {
    guard !isStopped else {
      return .error(statusCode: 503, .internalError("MCP service unavailable"))
    }
    await expireSessions()

    // Debug logging
    let bodyPreview: String
    if let body = request.body {
      bodyPreview = String(data: body.prefix(512), encoding: .utf8) ?? "<binary \(body.count)B>"
    } else {
      bodyPreview = "<nil>"
    }
    let headersDesc = request.headers.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    Self.debugLog("[MCPSessionRegistry] handle method=\(request.method) path=\(request.path ?? "nil") headers=[\(headersDesc)] body=\(bodyPreview)")

    if let sessionID = extractSessionID(from: request) {
      Self.debugLog("[MCPSessionRegistry] found sessionID=\(sessionID)")
      return await handleExisting(request, sessionID: sessionID)
    }
    if isDiscover(request) {
      Self.debugLog("[MCPSessionRegistry] isDiscover=true, answering stateless discovery")
      return await handleDiscover(for: request)
    }
    if isModernRequest(request) {
      Self.debugLog("[MCPSessionRegistry] modern request without session")
      return await handleModernRequest(request)
    }
    if isInitialize(request) {
      Self.debugLog("[MCPSessionRegistry] isInitialize=true, creating session")
      return await createSession(for: request)
    }
    if request.body == nil || request.body?.isEmpty == true {
      Self.debugLog("[MCPSessionRegistry] probe/empty request, returning 200 OK")
      return .data(Data("{}".utf8), headers: [HTTPHeaderName.contentType: "application/json"])
    }
    Self.debugLog("[MCPSessionRegistry] isInitialize=false, returning 400")
    return .error(
      statusCode: 400,
      .invalidRequest("Bad Request: Missing MCP session identifier")
    )
  }

  private static func debugLog(_ msg: String) {
    let logMsg = msg + "\n"
    if let data = logMsg.data(using: .utf8),
      let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/codex_bridge_tunnel.log")) {
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
      try? handle.close()
    }
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
      let queryItems = urlComponents.queryItems {
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
    return request.header("Mcp-Protocol-Version") == "2026-07-28"
      || request.header("Mcp-Method") != nil
  }

  private func handleModernRequest(_ request: HTTPRequest) async -> HTTPResponse {
    guard let statelessServerFactory else {
      return .error(statusCode: 400, .invalidRequest("Modern MCP requests are unavailable"))
    }
    let transport = StatelessHTTPServerTransport(
      validationPipeline: StandardValidationPipeline(validators: [
        OriginValidator(
          allowedHosts: [
            "127.0.0.1:*",
            "localhost:*",
            "[::1]:*",
          ],
          allowedOrigins: [
            "http://127.0.0.1:*",
            "http://localhost:*",
            "http://[::1]:*",
            "https://chatgpt.com",
            "https://chat.openai.com",
            "https://platform.openai.com",
          ]
        ),
        AcceptHeaderValidator(mode: .jsonOnly),
        ContentTypeValidator(),
      ])
    )
    do {
      let server = try await statelessServerFactory()
      try await server.start(transport: transport)
      let response = await transport.handleRequest(request)
      await server.stop()
      Self.debugLog("[MCPSessionRegistry] modern response status=\(response.statusCode)")
      return response
    } catch {
      Self.debugLog("[MCPSessionRegistry] modern request failed: \(error)")
      return .error(statusCode: 500, .internalError("Modern MCP request failed"))
    }
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
      "supportedVersions": ["2026-07-28", Version.latest],
      "capabilities": ["tools": [:]],
      "_meta": [
        "io.modelcontextprotocol/serverInfo": [
          "name": "Codex Bridge",
          "version": "1.0.0",
        ]
      ],
      "instructions": "Codex Bridge exposes locally registered projects and Codex tasks. All actions are executed on the user's machine after local approval.",
    ]
    let response: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "result": result,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: response) else {
      return .error(statusCode: 500, .internalError("Discovery encoding failed"))
    }
    Self.debugLog(
      "[MCPSessionRegistry] discovery response status=200 body=\(String(decoding: data, as: UTF8.self))"
    )
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
    sessions.removeAll(keepingCapacity: false)
    for server in active {
      await server.stop()
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

  private func handleExisting(
    _ request: HTTPRequest,
    sessionID: String
  ) async -> HTTPResponse {
    guard var context = sessions[sessionID] else {
      return .error(statusCode: 404, .invalidRequest("Not Found: Session unavailable"))
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

  private func createSession(for request: HTTPRequest) async -> HTTPResponse {
    guard !isStopped, sessions.count + pendingSessionCreations < limits.maximumSessions else {
      return .error(statusCode: 503, .internalError("Session capacity reached"))
    }
    pendingSessionCreations += 1
    defer { pendingSessionCreations -= 1 }

    let sessionID = makeUniqueSessionID()
    let validation = StandardValidationPipeline(validators: [
      OriginValidator(
        allowedHosts: [
          "127.0.0.1:\(boundPort)",
          "localhost:\(boundPort)",
          "[::1]:\(boundPort)",
        ],
        allowedOrigins: [
          "http://127.0.0.1:\(boundPort)",
          "http://localhost:\(boundPort)",
          "http://[::1]:\(boundPort)",
          "https://chatgpt.com",
          "https://chat.openai.com",
          "https://platform.openai.com",
        ]
      ),
      AcceptHeaderValidator(mode: .jsonOnly),
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
      let createdServer = try await serverFactory(transport)
      server = createdServer
      try await createdServer.start(transport: transport)
      guard !isStopped else {
        await createdServer.stop()
        return .error(statusCode: 503, .internalError("MCP service unavailable"))
      }
      let now = clock.now
      sessions[sessionID] = SessionContext(
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

  private func closeSession(_ sessionID: String) async {
    guard let context = sessions.removeValue(forKey: sessionID) else { return }
    await context.server.stop()
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
      decoded.method == Initialize.name {
      return true
    }
    if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      object["method"] as? String == Initialize.name {
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
