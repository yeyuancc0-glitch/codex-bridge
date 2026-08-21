import Foundation
import MCP

public struct MCPBridgeEndpoint: Sendable {
  public let host: String
  public let port: Int
  public let localURL: URL

  public init(host: String, port: Int, localURL: URL) {
    self.host = host
    self.port = port
    self.localURL = localURL
  }
}

public enum MCPBridgeServerError: Error, Equatable, Sendable {
  case startInProgress
  case stopInProgress
  case startCancelled
  case invalidBoundEndpoint
}

public actor MCPBridgeServer {
  private enum Lifecycle {
    case stopped
    case starting(UUID, MCPHTTPListener, MCPRequestRouter)
    case running(
      endpoint: MCPBridgeEndpoint,
      listener: MCPHTTPListener,
      router: MCPRequestRouter,
      expiryTask: Task<Void, Never>
    )
  }

  private let makeServer: @Sendable (MCPClientID) async -> Server
  private let httpConfiguration: MCPHTTPConfiguration
  private let sessionLimits: MCPSessionRegistry.Limits
  private let clientAdmission: MCPClientAdmissionGate?
  private var lifecycle = Lifecycle.stopped
  private var currentStopID: UUID?
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    appVersion: String,
    queries: any BridgeMCPQueries,
    taskOperations: (any BridgeMCPTaskOperations)? = nil,
    projectOperations: (any BridgeMCPProjectOperations)? = nil,
    httpConfiguration: MCPHTTPConfiguration,
    sessionLimits: MCPSessionRegistry.Limits = .init(),
    clientAdmission: MCPClientAdmissionGate? = nil
  ) {
    precondition(!appVersion.isEmpty)
    let factory = MCPServerFactory(
      appVersion: appVersion,
      queries: queries,
      taskOperations: taskOperations,
      projectOperations: projectOperations
    )
    makeServer = { _ in await factory.makeServer() }
    self.httpConfiguration = httpConfiguration
    self.sessionLimits = sessionLimits
    self.clientAdmission = clientAdmission
  }

  public init(
    appVersion: String,
    service: any BridgeMCPServiceAPI,
    exposureMode: MCPServiceExposureMode,
    httpConfiguration: MCPHTTPConfiguration,
    sessionLimits: MCPSessionRegistry.Limits = .init(),
    clientAdmission: MCPClientAdmissionGate? = nil
  ) {
    precondition(!appVersion.isEmpty)
    let factory = MCPServiceServerFactory(
      appVersion: appVersion,
      service: service,
      exposureMode: exposureMode
    )
    makeServer = { _ in await factory.makeServer() }
    self.httpConfiguration = httpConfiguration
    self.sessionLimits = sessionLimits
    self.clientAdmission = clientAdmission
  }

  public init(
    appVersion: String,
    service: any BridgeMCPServiceAPI,
    exposureMode: @escaping @Sendable (MCPClientID) async -> MCPServiceExposureMode,
    httpConfiguration: MCPHTTPConfiguration,
    sessionLimits: MCPSessionRegistry.Limits = .init(),
    clientAdmission: MCPClientAdmissionGate? = nil
  ) {
    precondition(!appVersion.isEmpty)
    makeServer = { clientID in
      let mode = await exposureMode(clientID)
      return await MCPServiceServerFactory(
        appVersion: appVersion,
        service: service,
        exposureMode: mode,
        clientID: clientID
      ).makeServer()
    }
    self.httpConfiguration = httpConfiguration
    self.sessionLimits = sessionLimits
    self.clientAdmission = clientAdmission
  }

  public func start() async throws -> MCPBridgeEndpoint {
    guard currentStopID == nil else {
      throw MCPBridgeServerError.stopInProgress
    }
    switch lifecycle {
    case .running(let endpoint, _, _, _):
      return endpoint
    case .starting:
      throw MCPBridgeServerError.startInProgress
    case .stopped:
      break
    }

    let identifier = UUID()
    let router = MCPRequestRouter()
    let listener = MCPHTTPListener(
      configuration: httpConfiguration,
      authenticatedHandler: { request in await router.handle(request) },
      emissionObserver: { emission in await router.record(emission) }
    )
    lifecycle = .starting(identifier, listener, router)

    do {
      let bound = try await listener.start()
      guard isStarting(identifier) else {
        await listener.stop()
        throw MCPBridgeServerError.startCancelled
      }

      let makeServer = makeServer
      let registry = MCPSessionRegistry(
        boundPort: bound.port,
        limits: sessionLimits,
        authenticatedServerFactory: { clientID, _ in
          await makeServer(clientID)
        },
        authenticatedStatelessServerFactory: { clientID in
          await makeServer(clientID)
        },
        clientAdmission: clientAdmission
      )
      await router.install(registry)

      guard isStarting(identifier) else {
        await listener.stop()
        await router.stop()
        throw MCPBridgeServerError.startCancelled
      }
      let endpoint = try makeEndpoint(bound)
      let expiryTask = Task {
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(60))
          } catch {
            return
          }
          await registry.expireSessions()
        }
      }
      lifecycle = .running(
        endpoint: endpoint,
        listener: listener,
        router: router,
        expiryTask: expiryTask
      )
      return endpoint
    } catch {
      if isStarting(identifier) {
        lifecycle = .stopped
      }
      await listener.stop()
      await router.stop()
      throw error
    }
  }

  public func stop() async {
    if currentStopID != nil {
      await withCheckedContinuation { continuation in
        stopWaiters.append(continuation)
      }
      return
    }
    let stopID = UUID()
    currentStopID = stopID
    let current = lifecycle
    lifecycle = .stopped
    switch current {
    case .stopped:
      break
    case .starting(_, let listener, let router):
      await listener.stop()
      await router.stop()
    case .running(_, let listener, let router, let expiryTask):
      expiryTask.cancel()
      await listener.stop()
      await router.stop()
    }
    guard currentStopID == stopID else { return }
    currentStopID = nil
    let waiters = stopWaiters
    stopWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume()
    }
  }

  public var endpoint: MCPBridgeEndpoint? {
    guard case .running(let endpoint, _, _, _) = lifecycle else { return nil }
    return endpoint
  }

  public func terminateSessions(for clientID: MCPClientID) async {
    guard case .running(_, _, let router, _) = lifecycle else { return }
    await router.terminateSessions(for: clientID)
  }

  public func activeSessionCount(for clientID: MCPClientID) async -> Int {
    guard case .running(_, _, let router, _) = lifecycle else { return 0 }
    return await router.activeSessionCount(for: clientID)
  }

  private func isStarting(_ identifier: UUID) -> Bool {
    guard case .starting(let current, _, _) = lifecycle else { return false }
    return current == identifier
  }

  private func makeEndpoint(_ bound: MCPHTTPBoundEndpoint) throws -> MCPBridgeEndpoint {
    let path =
      !httpConfiguration.usesHeaderAuthentication
      ? "/mcp/\(httpConfiguration.pathSecret)" : "/mcp"
    guard
      let url = URL(
        string: "http://\(bound.host):\(bound.port)\(path)"
      )
    else {
      throw MCPBridgeServerError.invalidBoundEndpoint
    }
    return MCPBridgeEndpoint(host: bound.host, port: bound.port, localURL: url)
  }
}

private actor MCPRequestRouter {
  private var registry: MCPSessionRegistry?

  func install(_ registry: MCPSessionRegistry) {
    self.registry = registry
  }

  func handle(_ request: AuthenticatedMCPRequest) async -> HTTPResponse {
    guard let registry else {
      return .error(statusCode: 503, .internalError("MCP service unavailable"))
    }
    return await registry.handle(request)
  }

  func terminateSessions(for clientID: MCPClientID) async {
    await registry?.terminateSessions(for: clientID)
  }

  func activeSessionCount(for clientID: MCPClientID) async -> Int {
    await registry?.activeSessionCount(for: clientID) ?? 0
  }

  func record(_ emission: MCPHTTPEmission) async {
    guard let registry else { return }
    await registry.recordEmittedBytes(
      sessionID: emission.sessionID,
      byteCount: emission.byteCount
    )
    if emission.kind == .sessionTerminated {
      await registry.terminateSession(emission.sessionID)
    }
  }

  func stop() async {
    let current = registry
    registry = nil
    await current?.stop()
  }
}
