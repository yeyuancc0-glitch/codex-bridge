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
  static let modernProtocolVersion = "2026-07-28"

  public typealias ServerFactory = @Sendable (StatefulHTTPServerTransport) async throws -> Server
  public typealias AuthenticatedServerFactory =
    @Sendable (MCPClientID, StatefulHTTPServerTransport) async throws -> Server
  public typealias StatelessServerFactory = @Sendable () async throws -> Server
  public typealias AuthenticatedStatelessServerFactory =
    @Sendable (MCPClientID) async throws -> Server
  public typealias DiscoveryInstructionsProvider = @Sendable (MCPClientID) async -> String

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

  struct SessionContext {
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

  struct ActiveStatelessServer {
    let clientID: MCPClientID
    let server: Server
    let requestTask: Task<HTTPResponse, Never>
  }

  struct FixedSessionIDGenerator: SessionIDGenerator {
    let value: String

    func generateSessionID() -> String {
      value
    }
  }

  let boundPort: Int
  let limits: Limits
  let serverFactory: AuthenticatedServerFactory
  let statelessServerFactory: AuthenticatedStatelessServerFactory?
  let clientAdmission: MCPClientAdmissionGate?
  let discoveryInstructionsProvider: DiscoveryInstructionsProvider?
  let clock = ContinuousClock()
  var sessions: [String: SessionContext] = [:]
  var activeStatelessServers: [UUID: ActiveStatelessServer] = [:]
  var pendingSessionCreations = 0
  var pendingSessionCreationsByClient: [MCPClientID: Int] = [:]
  var isStopped = false

  public init(
    boundPort: Int,
    limits: Limits = .init(),
    serverFactory: @escaping ServerFactory,
    statelessServerFactory: StatelessServerFactory? = nil,
    clientAdmission: MCPClientAdmissionGate? = nil,
    discoveryInstructionsProvider: DiscoveryInstructionsProvider? = nil
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
    self.discoveryInstructionsProvider = discoveryInstructionsProvider
  }

  public init(
    boundPort: Int,
    limits: Limits = .init(),
    authenticatedServerFactory: @escaping AuthenticatedServerFactory,
    authenticatedStatelessServerFactory: AuthenticatedStatelessServerFactory? = nil,
    clientAdmission: MCPClientAdmissionGate? = nil,
    discoveryInstructionsProvider: DiscoveryInstructionsProvider? = nil
  ) {
    self.boundPort = boundPort
    self.limits = limits
    self.serverFactory = authenticatedServerFactory
    self.statelessServerFactory = authenticatedStatelessServerFactory
    self.clientAdmission = clientAdmission
    self.discoveryInstructionsProvider = discoveryInstructionsProvider
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
      return await handleDiscover(for: request, clientID: clientID)
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
}
