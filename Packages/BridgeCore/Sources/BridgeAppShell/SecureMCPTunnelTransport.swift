import BridgeSecurity
import BridgeTunnel
import Foundation

actor SecureMCPTunnelTransport: ChatGPTBridgeTransport {
  private enum RestartAttempt {
    case ready(any DesktopTunnelManaging)
    case retry
    case actionRequired
    case superseded
  }

  private let mcp: any DesktopMCPServing
  private let tunnelFactory: any DesktopTunnelManagerBuilding
  private let tunnelID: TunnelID
  private let runtimeKeyReference: SecretReference
  private let localMCPHeaderSecret: String
  private let restartDelays: [Duration]
  private var localMCPURL: URL?
  private var tunnel: (any DesktopTunnelManaging)?
  private var restartTask: Task<Void, Never>?
  private var lifecycleGeneration: UInt64 = 0
  private var failed = false
  private var restartExhausted = false
  private var lastActionRequired = false

  init(
    mcp: any DesktopMCPServing,
    tunnelFactory: any DesktopTunnelManagerBuilding,
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPHeaderSecret: String,
    restartDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
  ) {
    self.mcp = mcp
    self.tunnelFactory = tunnelFactory
    self.tunnelID = tunnelID
    self.runtimeKeyReference = runtimeKeyReference
    self.localMCPHeaderSecret = localMCPHeaderSecret
    self.restartDelays = Array(restartDelays.prefix(5))
  }

  func start() async throws {
    lifecycleGeneration &+= 1
    failed = false
    restartExhausted = false
    lastActionRequired = false
    do {
      let url = try await mcp.start(authentication: .header(secret: localMCPHeaderSecret))
      try await mcp.testConnection()
      let tunnel = try await tunnelFactory.make(
        tunnelID: tunnelID,
        runtimeKeyReference: runtimeKeyReference,
        localMCPURL: url,
        localMCPHeaderSecret: localMCPHeaderSecret
      )
      self.tunnel = tunnel
      localMCPURL = url
      try await tunnel.start()
    } catch {
      failed = true
      lastActionRequired = true
      await tunnel?.stop()
      tunnel = nil
      localMCPURL = nil
      await mcp.stop()
      throw error
    }
  }

  func stop() async {
    lifecycleGeneration &+= 1
    let restartTask = restartTask
    self.restartTask = nil
    restartTask?.cancel()
    let tunnel = tunnel
    self.tunnel = nil
    localMCPURL = nil
    failed = false
    restartExhausted = false
    lastActionRequired = false
    await tunnel?.stop()
    await restartTask?.value
    await mcp.stop()
  }

  func testConnection() async throws {
    guard let tunnel, localMCPURL != nil else { throw DesktopTransportError.notStarted }
    try await mcp.testConnection()
    guard await tunnel.acceptsRemoteSubmissions() else {
      throw DesktopTransportError.connectionFailed
    }
  }

  func health() async -> DesktopTransportHealth {
    if restartTask != nil {
      return health(lifecycle: .degraded, actionRequired: false)
    }
    guard let tunnel else {
      return health(
        lifecycle: failed ? .failed : .stopped,
        actionRequired: lastActionRequired || restartExhausted
      )
    }
    let generation = lifecycleGeneration
    let lifecycle = await tunnel.state()
    let diagnostics = await tunnel.diagnostics()
    let acceptsRemoteSubmissions = await tunnel.acceptsRemoteSubmissions()
    guard generation == lifecycleGeneration, self.tunnel != nil else {
      return health(lifecycle: .stopped, actionRequired: false)
    }
    if lifecycle == .failed, !diagnostics.actionRequired {
      beginRestartIfNeeded(generation: generation)
    } else if diagnostics.actionRequired {
      lastActionRequired = true
    }
    return DesktopTransportHealth(
      lifecycle: restartTask == nil ? lifecycle : .degraded,
      acceptsRemoteSubmissions: restartTask == nil && acceptsRemoteSubmissions
        && !diagnostics.actionRequired,
      endpointDescription: "OpenAI Secure MCP Tunnel",
      localMCPURL: localMCPURL,
      actionRequired: diagnostics.actionRequired
    )
  }

  private func beginRestartIfNeeded(generation: UInt64) {
    guard restartTask == nil, !restartDelays.isEmpty, !restartExhausted,
      localMCPURL != nil, generation == lifecycleGeneration
    else { return }
    restartTask = Task { [weak self] in
      await self?.restartFailedTunnel(generation: generation)
    }
  }

  private func restartFailedTunnel(generation: UInt64) async {
    for delay in restartDelays {
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled, generation == lifecycleGeneration else { return }
      switch await attemptRestart(generation: generation) {
      case .ready(let replacement):
        tunnel = replacement
        failed = false
        restartExhausted = false
        lastActionRequired = false
        restartTask = nil
        return
      case .retry:
        continue
      case .actionRequired:
        failed = true
        lastActionRequired = true
        restartTask = nil
        return
      case .superseded:
        return
      }
    }
    guard generation == lifecycleGeneration, !Task.isCancelled else { return }
    failed = true
    restartExhausted = true
    restartTask = nil
  }

  private func attemptRestart(generation: UInt64) async -> RestartAttempt {
    guard let localMCPURL, generation == lifecycleGeneration else { return .superseded }
    let previous = tunnel
    tunnel = nil
    await previous?.stop()
    guard generation == lifecycleGeneration, !Task.isCancelled else { return .superseded }

    var candidate: (any DesktopTunnelManaging)?
    do {
      let created = try await tunnelFactory.make(
        tunnelID: tunnelID,
        runtimeKeyReference: runtimeKeyReference,
        localMCPURL: localMCPURL,
        localMCPHeaderSecret: localMCPHeaderSecret
      )
      candidate = created
      try await created.start()
      let lifecycle = await created.state()
      let diagnostics = await created.diagnostics()
      let acceptsRemoteSubmissions = await created.acceptsRemoteSubmissions()
      guard generation == lifecycleGeneration, !Task.isCancelled else {
        await created.stop()
        return .superseded
      }
      guard lifecycle == .ready, acceptsRemoteSubmissions, !diagnostics.actionRequired else {
        await created.stop()
        return diagnostics.actionRequired ? .actionRequired : .retry
      }
      return .ready(created)
    } catch {
      let actionRequired: Bool
      if let candidate {
        actionRequired = await candidate.diagnostics().actionRequired
      } else {
        actionRequired = false
      }
      await candidate?.stop()
      return actionRequired ? .actionRequired : .retry
    }
  }

  private func health(
    lifecycle: TunnelLifecycle,
    actionRequired: Bool
  ) -> DesktopTransportHealth {
    DesktopTransportHealth(
      lifecycle: lifecycle,
      acceptsRemoteSubmissions: false,
      endpointDescription: "OpenAI Secure MCP Tunnel",
      localMCPURL: localMCPURL,
      actionRequired: actionRequired
    )
  }
}
