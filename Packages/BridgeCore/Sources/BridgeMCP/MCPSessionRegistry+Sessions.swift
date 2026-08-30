import Foundation
import Logging
import MCP

extension MCPSessionRegistry {
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

  func handleExisting(
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

  func createSession(
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

  func retireQwenSessionsForAdmission(clientID: MCPClientID) -> [Server] {
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

  func sessionCapacityReached(for clientID: MCPClientID) -> Bool {
    let clientSessionCount = sessions.values.lazy.filter { $0.clientID == clientID }.count
    let pendingForClient = pendingSessionCreationsByClient[clientID, default: 0]
    return sessions.count + pendingSessionCreations >= limits.maximumSessions
      || clientSessionCount + pendingForClient >= limits.maximumSessionsPerClient
  }

  func closeSession(_ sessionID: String) async {
    guard let context = sessions.removeValue(forKey: sessionID) else { return }
    await context.server.stop()
  }

  func removeStatelessServer(_ serverID: UUID) -> ActiveStatelessServer? {
    activeStatelessServers.removeValue(forKey: serverID)
  }
}
