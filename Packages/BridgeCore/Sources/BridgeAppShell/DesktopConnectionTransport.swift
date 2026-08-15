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
  func setRemoteTaskAdmissionLeaseCheck(
    _ check: (@Sendable () async -> DesktopRemoteAdmissionLease?)?
  ) async
}

extension DesktopMCPServing {
  func setRemoteTaskAdmissionCheck(_: (@Sendable () async -> Bool)?) async {}
  func setRemoteTaskAdmissionLeaseCheck(
    _: (@Sendable () async -> DesktopRemoteAdmissionLease?)?
  ) async {}
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

final class DesktopRemoteAdmissionLease: @unchecked Sendable {
  private let lock = NSLock()
  private var gate: DesktopRemoteAdmissionGate?

  fileprivate init(gate: DesktopRemoteAdmissionGate) {
    self.gate = gate
  }

  func release() {
    let gate = lock.withLock { () -> DesktopRemoteAdmissionGate? in
      let current = self.gate
      self.gate = nil
      return current
    }
    gate?.releaseLease()
  }

  deinit { release() }
}

final class DesktopRemoteAdmissionGate: @unchecked Sendable {
  struct Snapshot: Equatable, Sendable {
    let epoch: UInt64
    let permitsRemoteSubmissions: Bool
  }

  private enum State: Equatable {
    case open
    case asleep
    case revalidating
    case stopping
  }

  struct Transition: Equatable, Sendable {
    fileprivate let epoch: UInt64
    fileprivate let reopensOnSuccess: Bool
  }

  private let lock = NSLock()
  private var epoch: UInt64 = 0
  private var state = State.open
  private var inFlightLeases = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(
        epoch: epoch,
        permitsRemoteSubmissions: state == .open
      )
    }
  }

  @discardableResult
  func closeForSleep() -> UInt64 {
    lock.withLock {
      guard state != .stopping else { return epoch }
      epoch &+= 1
      state = .asleep
      return epoch
    }
  }

  func beginWakeRevalidation() -> Transition? {
    lock.withLock {
      guard state == .asleep else { return nil }
      epoch &+= 1
      state = .revalidating
      return Transition(epoch: epoch, reopensOnSuccess: true)
    }
  }

  func beginReplacement() -> Transition? {
    lock.withLock {
      guard state != .stopping else { return nil }
      let reopens = state == .open
      epoch &+= 1
      if reopens { state = .revalidating }
      return Transition(epoch: epoch, reopensOnSuccess: reopens)
    }
  }

  func complete(_ transition: Transition) -> Bool {
    lock.withLock {
      guard state != .stopping else { return false }
      guard epoch == transition.epoch else { return state == .asleep }
      if transition.reopensOnSuccess {
        guard state == .revalidating else { return false }
        state = .open
      } else {
        guard state == .asleep else { return false }
      }
      return true
    }
  }

  func closePermanently() {
    lock.withLock {
      epoch &+= 1
      state = .stopping
    }
  }

  func acquireLease(expectedEpoch: UInt64) -> DesktopRemoteAdmissionLease? {
    lock.withLock {
      guard epoch == expectedEpoch, state == .open else { return nil }
      inFlightLeases += 1
      return DesktopRemoteAdmissionLease(gate: self)
    }
  }

  func waitForLeaseDrain() async {
    if lock.withLock({ inFlightLeases == 0 }) { return }
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock { () -> Bool in
        guard inFlightLeases > 0 else { return true }
        drainWaiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  fileprivate func releaseLease() {
    let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      precondition(inFlightLeases > 0)
      inFlightLeases -= 1
      guard inFlightLeases == 0 else { return [] }
      let current = drainWaiters
      drainWaiters.removeAll(keepingCapacity: false)
      return current
    }
    for waiter in waiters { waiter.resume() }
  }
}

actor DesktopConnectionRuntime {
  private let mcp: any DesktopMCPServing
  private let remoteTester: any DesktopRemoteMCPTesting
  private let tunnelFactory: any DesktopTunnelManagerBuilding
  private let status: BridgeStatusStore?
  private let monitorInterval: Duration
  private let admissionGate: DesktopRemoteAdmissionGate
  private var active: (any ChatGPTBridgeTransport)?
  private var healthContinuations: [UUID: AsyncStream<DesktopTransportHealth>.Continuation] = [:]
  private var monitorTask: Task<Void, Never>?
  private var lastHealth = DesktopTransportHealth.stopped
  private var activeGeneration: UInt64 = 0
  private var transportMutationActive = false
  private var transportMutationWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    mcp: any DesktopMCPServing,
    remoteTester: any DesktopRemoteMCPTesting = DesktopRemoteMCPClient(),
    tunnelFactory: any DesktopTunnelManagerBuilding,
    status: BridgeStatusStore? = nil,
    monitorInterval: Duration = .seconds(2),
    admissionGate: DesktopRemoteAdmissionGate = DesktopRemoteAdmissionGate()
  ) {
    self.mcp = mcp
    self.remoteTester = remoteTester
    self.tunnelFactory = tunnelFactory
    self.status = status
    self.monitorInterval = monitorInterval
    self.admissionGate = admissionGate
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
    let generation = activeGeneration
    let gate = admissionGate.snapshot()
    do {
      try await active.testConnection()
      guard generation == activeGeneration, gate.epoch == admissionGate.snapshot().epoch,
        self.active != nil
      else {
        throw DesktopTransportError.connectionFailed
      }
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
    let health = effectiveHealth(await active?.health() ?? .stopped)
    await record(health)
    return health
  }

  func acceptsRemoteSubmissionsNow() async -> Bool {
    let lease = await acquireRemoteSubmissionLease()
    lease?.release()
    return lease != nil
  }

  func acquireRemoteSubmissionLease() async -> DesktopRemoteAdmissionLease? {
    let generation = activeGeneration
    let gate = admissionGate.snapshot()
    guard gate.permitsRemoteSubmissions else { return nil }
    guard let active else { return nil }
    let accepts = await active.health().acceptsRemoteSubmissions
    let currentGate = admissionGate.snapshot()
    guard generation == activeGeneration, gate.epoch == currentGate.epoch, self.active != nil,
      currentGate.permitsRemoteSubmissions
    else { return nil }
    guard accepts else { return nil }
    return admissionGate.acquireLease(expectedEpoch: gate.epoch)
  }

  func waitForRemoteSubmissionDrain() async {
    await admissionGate.waitForLeaseDrain()
  }

  func suspendRemoteAdmissionsForSleep() async {
    admissionGate.closeForSleep()
    await record(effectiveHealth(await active?.health() ?? .stopped))
  }

  func revalidateRemoteAdmissionsAfterWake() async throws {
    guard let transition = admissionGate.beginWakeRevalidation() else { return }
    let generation = activeGeneration
    guard let active else {
      guard admissionGate.complete(transition) else {
        throw DesktopTransportError.connectionFailed
      }
      await record(.stopped)
      return
    }
    do {
      try await active.testConnection()
      let health = await active.health()
      guard generation == activeGeneration, self.active != nil,
        admissionGate.complete(transition)
      else {
        throw DesktopTransportError.connectionFailed
      }
      await record(health)
    } catch {
      if transition.epoch == admissionGate.snapshot().epoch, generation == activeGeneration {
        await record(effectiveHealth(await active.health()))
      }
      throw error
    }
  }

  func stop() async {
    await beginTransportMutation()
    defer { endTransportMutation() }
    activeGeneration &+= 1
    let transition = admissionGate.beginReplacement()
    await admissionGate.waitForLeaseDrain()
    monitorTask?.cancel()
    monitorTask = nil
    let active = active
    self.active = nil
    await active?.stop()
    if let transition { _ = admissionGate.complete(transition) }
    await record(.stopped)
  }

  func shutdown() async {
    admissionGate.closePermanently()
    await beginTransportMutation()
    defer { endTransportMutation() }
    activeGeneration &+= 1
    await admissionGate.waitForLeaseDrain()
    monitorTask?.cancel()
    monitorTask = nil
    let active = active
    self.active = nil
    await active?.stop()
    await record(.stopped)
  }

  private func replace(with transport: any ChatGPTBridgeTransport) async throws -> URL {
    await beginTransportMutation()
    defer { endTransportMutation() }
    activeGeneration &+= 1
    let generation = activeGeneration
    guard let transition = admissionGate.beginReplacement() else {
      throw DesktopTransportError.connectionFailed
    }
    let previous = active
    active = nil
    monitorTask?.cancel()
    monitorTask = nil
    await admissionGate.waitForLeaseDrain()
    await previous?.stop()
    do {
      try await transport.start()
      let health = await transport.health()
      guard let localMCPURL = health.localMCPURL else {
        await transport.stop()
        throw DesktopTransportError.connectionFailed
      }
      guard generation == activeGeneration,
        admissionGate.complete(transition)
      else {
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

  private func beginTransportMutation() async {
    guard transportMutationActive else {
      transportMutationActive = true
      return
    }
    await withCheckedContinuation { transportMutationWaiters.append($0) }
  }

  private func endTransportMutation() {
    guard let next = transportMutationWaiters.first else {
      transportMutationActive = false
      return
    }
    transportMutationWaiters.removeFirst()
    next.resume()
  }

  private func pollHealth() async {
    guard let active else { return }
    await record(effectiveHealth(await active.health()))
  }

  private func effectiveHealth(_ health: DesktopTransportHealth) -> DesktopTransportHealth {
    guard !admissionGate.snapshot().permitsRemoteSubmissions else { return health }
    return DesktopTransportHealth(
      lifecycle: health.lifecycle,
      acceptsRemoteSubmissions: false,
      endpointDescription: health.endpointDescription,
      localMCPURL: health.localMCPURL,
      actionRequired: health.actionRequired
    )
  }

  private func record(_ rawHealth: DesktopTransportHealth) async {
    let health = effectiveHealth(rawHealth)
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
    degradations.append(DesktopSupervisorAvailability.degradation)
    await status.update(
      BridgeStatusSnapshot(
        appVersion: "0.1.0",
        mcpState: health.localMCPURL == nil ? "stopped" : "ready",
        tunnelState: health.lifecycle.rawValue,
        executionState: "idle",
        supervisorState: "unavailable",
        degradations: degradations,
        pendingApprovalCount: 0
      )
    )
  }
}
