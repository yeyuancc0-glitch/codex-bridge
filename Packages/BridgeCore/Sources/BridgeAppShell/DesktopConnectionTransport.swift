import BridgeApplication
import BridgeMCP
import BridgeSecurity
import BridgeTunnel
import Foundation

enum DesktopTransportError: LocalizedError, Equatable, Sendable {
  case notStarted
  case invalidManualEndpoint
  case invalidAuthorization
  case helperUnavailable
  case helperDigestUnavailable
  case connectionFailed

  var errorDescription: String? {
    switch self {
    case .notStarted: "连接尚未启动。"
    case .invalidManualEndpoint:
      "自备 Endpoint 必须是无用户信息、查询或片段的 HTTPS /mcp 地址。"
    case .invalidAuthorization: "Authorization 请求头值无效。"
    case .helperUnavailable: "当前 App 未捆绑签名后的 OpenAI Tunnel helper。"
    case .helperDigestUnavailable: "Tunnel helper 的签名后 SHA-256 资源缺失或无效。"
    case .connectionFailed: "连接未通过严格 MCP initialize 与工具目录检查。"
    }
  }
}

struct DesktopTransportHealth: Equatable, Sendable {
  let lifecycle: TunnelLifecycle
  let acceptsRemoteSubmissions: Bool
  let endpointDescription: String
  let localMCPURL: URL?
  let actionRequired: Bool

  static let stopped = DesktopTransportHealth(
    lifecycle: .stopped,
    acceptsRemoteSubmissions: false,
    endpointDescription: "尚未配置",
    localMCPURL: nil,
    actionRequired: false
  )
}

enum DesktopOnboardingTransportConfiguration: Sendable {
  case local(pathSecret: String)
  case manual(pathSecret: String, endpoint: URL, authorization: String)
  case secure(
    headerSecret: String,
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference
  )
}

protocol ChatGPTBridgeTransport: Sendable {
  func start() async throws
  func stop() async
  func testConnection() async throws
  func health() async -> DesktopTransportHealth
}

protocol DesktopMCPServing: Sendable {
  func start(authentication: DesktopMCPAuthentication) async throws -> URL
  func testConnection() async throws
  func stop() async
  func setRemoteTaskAdmissionCheck(
    _ check: (@Sendable () async -> Bool)?
  ) async
}

extension DesktopMCPServing {
  func setRemoteTaskAdmissionCheck(_: (@Sendable () async -> Bool)?) async {}
}

protocol DesktopRemoteMCPTesting: Sendable {
  func validate(endpoint: URL, authorization: String) async throws
}

protocol DesktopTunnelManaging: Sendable {
  func start() async throws
  func stop() async
  func state() async -> TunnelLifecycle
  func acceptsRemoteSubmissions() async -> Bool
  func diagnostics() async -> TunnelDiagnostics
}

protocol DesktopTunnelManagerBuilding: Sendable {
  func make(
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async throws -> any DesktopTunnelManaging
}

extension TunnelManager: DesktopTunnelManaging {}

actor DesktopConnectionRuntime {
  private let mcp: any DesktopMCPServing
  private let remoteTester: any DesktopRemoteMCPTesting
  private let tunnelFactory: any DesktopTunnelManagerBuilding
  private let status: BridgeStatusStore?
  private let monitorInterval: Duration
  private var active: (any ChatGPTBridgeTransport)?
  private var healthContinuations: [UUID: AsyncStream<DesktopTransportHealth>.Continuation] = [:]
  private var monitorTask: Task<Void, Never>?
  private var lastHealth = DesktopTransportHealth.stopped
  private var activeGeneration: UInt64 = 0

  init(
    mcp: any DesktopMCPServing,
    remoteTester: any DesktopRemoteMCPTesting = DesktopRemoteMCPClient(),
    tunnelFactory: any DesktopTunnelManagerBuilding,
    status: BridgeStatusStore? = nil,
    monitorInterval: Duration = .seconds(2)
  ) {
    self.mcp = mcp
    self.remoteTester = remoteTester
    self.tunnelFactory = tunnelFactory
    self.status = status
    self.monitorInterval = monitorInterval
  }

  func configureLocal(authentication: DesktopMCPAuthentication) async throws -> URL {
    try await replace(with: LocalOnlyTransport(mcp: mcp, authentication: authentication))
  }

  func configureManual(
    localAuthentication: DesktopMCPAuthentication,
    endpoint: URL,
    authorization: String
  ) async throws -> URL {
    let transport = try ManualHTTPSTransport(
      mcp: mcp,
      remoteTester: remoteTester,
      localAuthentication: localAuthentication,
      endpoint: endpoint,
      authorization: authorization
    )
    return try await replace(with: transport)
  }

  func configureSecureTunnel(
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPHeaderSecret: String
  ) async throws -> URL {
    try await replace(
      with: SecureMCPTunnelTransport(
        mcp: mcp,
        tunnelFactory: tunnelFactory,
        tunnelID: tunnelID,
        runtimeKeyReference: runtimeKeyReference,
        localMCPHeaderSecret: localMCPHeaderSecret
      )
    )
  }

  func configure(_ configuration: DesktopOnboardingTransportConfiguration) async throws -> URL {
    switch configuration {
    case .local(let pathSecret):
      try await configureLocal(authentication: .path(secret: pathSecret))
    case .manual(let pathSecret, let endpoint, let authorization):
      try await configureManual(
        localAuthentication: .path(secret: pathSecret),
        endpoint: endpoint,
        authorization: authorization
      )
    case .secure(let headerSecret, let tunnelID, let runtimeKeyReference):
      try await configureSecureTunnel(
        tunnelID: tunnelID,
        runtimeKeyReference: runtimeKeyReference,
        localMCPHeaderSecret: headerSecret
      )
    }
  }

  func testConnection() async throws {
    guard let active else { throw DesktopTransportError.notStarted }
    do {
      try await active.testConnection()
      _ = await health()
    } catch {
      _ = await health()
      throw error
    }
  }

  func stateUpdates() -> AsyncStream<DesktopTransportHealth> {
    let identifier = UUID()
    let pair = AsyncStream.makeStream(
      of: DesktopTransportHealth.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    healthContinuations[identifier] = pair.continuation
    pair.continuation.yield(lastHealth)
    pair.continuation.onTermination = { @Sendable [weak self] _ in
      Task { await self?.removeHealthContinuation(identifier) }
    }
    return pair.stream
  }

  func health() async -> DesktopTransportHealth {
    let health = await active?.health() ?? .stopped
    await record(health)
    return health
  }

  func acceptsRemoteSubmissionsNow() async -> Bool {
    let generation = activeGeneration
    guard let active else { return false }
    let accepts = await active.health().acceptsRemoteSubmissions
    guard generation == activeGeneration, self.active != nil else { return false }
    return accepts
  }

  func stop() async {
    activeGeneration &+= 1
    monitorTask?.cancel()
    monitorTask = nil
    let active = active
    self.active = nil
    await active?.stop()
    await record(.stopped)
  }

  private func replace(with transport: any ChatGPTBridgeTransport) async throws -> URL {
    activeGeneration &+= 1
    let generation = activeGeneration
    let previous = active
    active = nil
    monitorTask?.cancel()
    monitorTask = nil
    await previous?.stop()
    do {
      try await transport.start()
      let health = await transport.health()
      guard let localMCPURL = health.localMCPURL else {
        await transport.stop()
        throw DesktopTransportError.connectionFailed
      }
      guard generation == activeGeneration else {
        await transport.stop()
        throw DesktopTransportError.connectionFailed
      }
      active = transport
      await record(health)
      beginMonitoring()
      return localMCPURL
    } catch {
      await transport.stop()
      await record(.stopped)
      throw error
    }
  }

  private func beginMonitoring() {
    monitorTask?.cancel()
    let interval = monitorInterval
    monitorTask = Task { [weak self, interval] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
        await self?.pollHealth()
      }
    }
  }

  private func pollHealth() async {
    guard let active else { return }
    await record(await active.health())
  }

  private func record(_ health: DesktopTransportHealth) async {
    let changed = health != lastHealth
    lastHealth = health
    await publishStatus(health)
    guard changed else { return }
    for continuation in healthContinuations.values { continuation.yield(health) }
  }

  private func removeHealthContinuation(_ identifier: UUID) {
    healthContinuations[identifier] = nil
  }

  private func publishStatus(_ health: DesktopTransportHealth) async {
    guard let status else { return }
    var degradations: [String] = []
    if !health.acceptsRemoteSubmissions {
      degradations.append("Remote ChatGPT connectivity is not available.")
    }
    await status.update(
      BridgeStatusSnapshot(
        appVersion: "0.1.0",
        mcpState: health.localMCPURL == nil ? "stopped" : "ready",
        tunnelState: health.lifecycle.rawValue,
        executionState: "idle",
        supervisorState: "idle",
        degradations: degradations,
        pendingApprovalCount: 0
      )
    )
  }
}
