import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import BridgeTunnel
import Foundation

public actor ServiceTunnelController {
  public static let runtimeKeyReference = SecretReference(
    rawValue: "service.tunnel-runtime-key"
  )

  private let settings: ServiceSettings
  private let runtimeStatus: ServiceRuntimeStatus
  private let secretStore: any SecretStore
  private let factory: any ServiceTunnelManagerBuilding
  private let monitorInterval: Duration
  private let restartDelays: [Duration]

  private var tunnelID: TunnelID?
  private var localMCPURL: URL?
  private var localMCPHeaderSecret: String?
  private var manager: (any ServiceTunnelManaging)?
  private var snapshot: ServiceTunnelSnapshot
  private var enabled = false
  private var generation: UInt64 = 0
  private var monitorTask: Task<Void, Never>?
  private var restartTask: Task<Void, Never>?
  private var isShutdown = false

  public init(
    settings: ServiceSettings,
    runtimeStatus: ServiceRuntimeStatus,
    secretStore: any SecretStore,
    factory: any ServiceTunnelManagerBuilding,
    monitorInterval: Duration = .seconds(2),
    restartDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
  ) {
    precondition(monitorInterval > .zero)
    self.settings = settings
    self.runtimeStatus = runtimeStatus
    self.secretStore = secretStore
    self.factory = factory
    self.monitorInterval = monitorInterval
    self.restartDelays = Array(restartDelays.prefix(5))
    snapshot = .unconfigured(helperAvailable: factory.helperAvailable())
  }

  public func bootstrap(
    localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async {
    guard !isShutdown else { return }
    self.localMCPURL = localMCPURL
    self.localMCPHeaderSecret = localMCPHeaderSecret
    await loadStoredConfiguration()
    guard enabled, snapshot.configured else {
      await publish(snapshot)
      return
    }
    Task { [weak self] in
      try? await self?.startConfigured()
    }
  }

  @discardableResult
  public func configure(
    tunnelID rawTunnelID: String,
    runtimeKey rawRuntimeKey: String
  ) async throws -> ServiceTunnelSnapshot {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    let tunnelID = try TunnelID(validating: rawTunnelID)
    let runtimeKey = try Self.validatedRuntimeKey(rawRuntimeKey)
    try await persist(tunnelID: tunnelID, runtimeKey: runtimeKey, enabled: true)
    self.tunnelID = tunnelID
    self.enabled = true
    snapshot = ServiceTunnelSnapshot(
      configured: true,
      enabled: true,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID.rawValue,
      lifecycle: .stopped,
      acceptsRemoteSubmissions: false,
      actionRequired: false
    )
    try await startConfigured()
    return snapshot
  }

  @discardableResult
  public func connect() async throws -> ServiceTunnelSnapshot {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    guard tunnelID != nil, hasRuntimeKey() else {
      throw ServiceTunnelError.notConfigured
    }
    try await settings.set("1", for: .tunnelEnabled)
    enabled = true
    try await startConfigured()
    return snapshot
  }

  public func disconnect() async throws {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    try await settings.set("0", for: .tunnelEnabled)
    enabled = false
    await stopCurrent(publishStopped: true)
  }

  public func clearConfiguration() async throws {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    enabled = false
    await stopCurrent(publishStopped: false)
    try await settings.set(nil, for: .tunnelID)
    try await settings.set(nil, for: .tunnelEnabled)
    do {
      try secretStore.remove(Self.runtimeKeyReference)
    } catch SecretStoreError.notFound {
    } catch {
      throw ServiceTunnelError.secretStoreUnavailable
    }
    tunnelID = nil
    snapshot = .unconfigured(helperAvailable: factory.helperAvailable())
    await publish(snapshot)
  }

  public func pauseForMCPRestart() async {
    guard !isShutdown else { return }
    await stopCurrent(publishStopped: false)
  }

  public func localMCPDidChange(
    _ localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async {
    guard !isShutdown else { return }
    let changed =
      self.localMCPURL != localMCPURL || self.localMCPHeaderSecret != localMCPHeaderSecret
    self.localMCPURL = localMCPURL
    self.localMCPHeaderSecret = localMCPHeaderSecret
    guard enabled, snapshot.configured else {
      await publish(snapshot)
      return
    }
    if changed || snapshot.lifecycle == .stopped || snapshot.lifecycle == .failed {
      Task { [weak self] in
        try? await self?.startConfigured()
      }
    }
  }

  public func status() async -> ServiceTunnelSnapshot {
    if let manager {
      await refresh(manager: manager, scheduleRestart: false)
    }
    return snapshot
  }

  public func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    await stopCurrent(publishStopped: false)
    let final = ServiceTunnelSnapshot(
      configured: snapshot.configured,
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: .stopped,
      acceptsRemoteSubmissions: false,
      actionRequired: snapshot.actionRequired
    )
    snapshot = final
    await runtimeStatus.updateTunnel(state: TunnelLifecycle.stopped.rawValue)
  }

  private func startConfigured() async throws {
    let context = try configuredStartContext()
    if try await currentManagerIsUsable() { return }
    try await requireAvailableHelper(tunnelID: context.tunnelID)
    let runGeneration = await prepareStart(tunnelID: context.tunnelID)
    do {
      try await launchCandidate(context: context, generation: runGeneration)
    } catch {
      await recordStartFailure(error, generation: runGeneration)
      if let serviceError = error as? ServiceTunnelError {
        throw serviceError
      }
      throw ServiceTunnelError.startFailed
    }
  }

  private typealias StartContext = (
    tunnelID: TunnelID,
    localMCPURL: URL,
    localMCPHeaderSecret: String
  )

  private func configuredStartContext() throws -> StartContext {
    guard !isShutdown else { throw ServiceTunnelError.serviceStopped }
    guard let tunnelID else { throw ServiceTunnelError.notConfigured }
    guard let localMCPURL, let localMCPHeaderSecret else {
      throw ServiceTunnelError.localMCPUnavailable
    }
    return (tunnelID, localMCPURL, localMCPHeaderSecret)
  }

  private func currentManagerIsUsable() async throws -> Bool {
    guard let current = manager else { return false }
    switch await current.state() {
    case .ready:
      return true
    case .starting, .authenticating, .connecting:
      return try await waitForCurrentManager()
    case .stopped, .failed, .degraded:
      return false
    }
  }

  private func waitForCurrentManager() async throws -> Bool {
    for _ in 0..<150 {
      try await Task.sleep(for: .milliseconds(200))
      guard !isShutdown, let active = manager else { return false }
      switch await active.state() {
      case .ready:
        await refresh(manager: active, scheduleRestart: true)
        return true
      case .failed, .stopped:
        return false
      case .starting, .authenticating, .connecting, .degraded:
        continue
      }
    }
    return false
  }

  private func requireAvailableHelper(tunnelID: TunnelID) async throws {
    guard factory.helperAvailable() else {
      let failure = ServiceTunnelSnapshot(
        configured: hasRuntimeKey(),
        enabled: enabled,
        helperAvailable: false,
        tunnelID: tunnelID.rawValue,
        lifecycle: .failed,
        acceptsRemoteSubmissions: false,
        actionRequired: true
      )
      snapshot = failure
      await publish(failure, degradation: "The signed tunnel-client helper is unavailable.")
      throw ServiceTunnelError.helperUnavailable
    }
  }

  private func prepareStart(tunnelID: TunnelID) async -> UInt64 {
    generation &+= 1
    cancelBackgroundTasks()
    let previous = manager
    manager = nil
    await previous?.stop()
    let starting = ServiceTunnelSnapshot(
      configured: true,
      enabled: enabled,
      helperAvailable: true,
      tunnelID: tunnelID.rawValue,
      lifecycle: .starting,
      acceptsRemoteSubmissions: false,
      actionRequired: false
    )
    snapshot = starting
    await publish(starting)
    return generation
  }

  private func launchCandidate(
    context: StartContext,
    generation runGeneration: UInt64
  ) async throws {
    let candidate = try await factory.make(
      tunnelID: context.tunnelID,
      runtimeKeyReference: Self.runtimeKeyReference,
      localMCPURL: context.localMCPURL,
      localMCPHeaderSecret: context.localMCPHeaderSecret
    )
    manager = candidate
    try await candidate.start()
    guard runGeneration == generation, !isShutdown else {
      await candidate.stop()
      throw ServiceTunnelError.serviceStopped
    }
    await refresh(manager: candidate, scheduleRestart: true)
    beginMonitor(generation: runGeneration)
  }

  private func recordStartFailure(_ error: any Error, generation runGeneration: UInt64) async {
    NSLog(
      "[ServiceTunnelController] Tunnel start failed: %@",
      String(describing: error)
    )
    if !(error is ServiceTunnelError), let diagnostics = await manager?.diagnostics() {
      NSLog(
        "[ServiceTunnelController] Diagnostics: stdout=%@, stderr=%@",
        diagnostics.standardOutput,
        diagnostics.standardError
      )
    }
    guard runGeneration == generation else { return }
    await failStart(candidate: manager, error: error)
  }

  private func failStart(
    candidate: (any ServiceTunnelManaging)?,
    error: any Error
  ) async {
    let diagnostics = await candidate?.diagnostics()
    await candidate?.stop()
    manager = nil
    let actionRequired = diagnostics?.actionRequired == true || Self.requiresLocalAction(error)
    let failed = ServiceTunnelSnapshot(
      configured: tunnelID != nil && hasRuntimeKey(),
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: .failed,
      acceptsRemoteSubmissions: false,
      actionRequired: actionRequired
    )
    snapshot = failed
    await publish(
      failed,
      degradation: actionRequired
        ? "Secure MCP Tunnel requires local action."
        : "Secure MCP Tunnel could not start."
    )
    if !actionRequired, enabled, !isShutdown, !restartDelays.isEmpty {
      beginRestart(generation: generation)
    }
  }

  private func beginMonitor(generation: UInt64) {
    guard monitorTask == nil else { return }
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: self?.monitorInterval ?? .seconds(2))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await self?.inspect(generation: generation)
      }
    }
  }

  private func inspect(generation: UInt64) async {
    guard generation == self.generation, enabled, let manager else { return }
    await refresh(manager: manager, scheduleRestart: true)
  }

  private func refresh(
    manager: any ServiceTunnelManaging,
    scheduleRestart: Bool
  ) async {
    let lifecycle = await manager.state()
    let diagnostics = await manager.diagnostics()
    let acceptsRemote = await manager.acceptsRemoteSubmissions()
    let current = ServiceTunnelSnapshot(
      configured: tunnelID != nil && hasRuntimeKey(),
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: lifecycle,
      acceptsRemoteSubmissions: acceptsRemote && !diagnostics.actionRequired,
      actionRequired: diagnostics.actionRequired
    )
    snapshot = current
    await publish(current, degradation: Self.degradation(for: current))

    guard scheduleRestart, lifecycle == .failed, enabled else { return }
    monitorTask?.cancel()
    monitorTask = nil
    if diagnostics.actionRequired || restartDelays.isEmpty {
      return
    }
    beginRestart(generation: generation)
  }

  private func beginRestart(generation: UInt64) {
    guard restartTask == nil else { return }
    restartTask = Task { [weak self] in
      await self?.restart(generation: generation)
    }
  }

  private func restart(generation: UInt64) async {
    for delay in restartDelays {
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard generation == self.generation, enabled, !isShutdown,
        let tunnelID, let localMCPURL, let localMCPHeaderSecret
      else {
        return
      }

      let previous = manager
      manager = nil
      await previous?.stop()
      do {
        let candidate = try await factory.make(
          tunnelID: tunnelID,
          runtimeKeyReference: Self.runtimeKeyReference,
          localMCPURL: localMCPURL,
          localMCPHeaderSecret: localMCPHeaderSecret
        )
        manager = candidate
        try await candidate.start()
        guard generation == self.generation, enabled, !isShutdown else {
          await candidate.stop()
          return
        }
        let lifecycle = await candidate.state()
        let diagnostics = await candidate.diagnostics()
        let accepts = await candidate.acceptsRemoteSubmissions()
        guard lifecycle == .ready, accepts, !diagnostics.actionRequired else {
          await candidate.stop()
          manager = nil
          if diagnostics.actionRequired {
            await markRestartFailure(actionRequired: true)
            restartTask = nil
            return
          }
          continue
        }
        restartTask = nil
        await refresh(manager: candidate, scheduleRestart: false)
        beginMonitor(generation: generation)
        return
      } catch {
        await manager?.stop()
        manager = nil
      }
    }
    guard generation == self.generation, enabled, !isShutdown else { return }
    await markRestartFailure(actionRequired: true)
    restartTask = nil
  }

  private func markRestartFailure(actionRequired: Bool) async {
    let failed = ServiceTunnelSnapshot(
      configured: tunnelID != nil && hasRuntimeKey(),
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: .failed,
      acceptsRemoteSubmissions: false,
      actionRequired: actionRequired
    )
    snapshot = failed
    await publish(
      failed,
      degradation: "Secure MCP Tunnel restart attempts were exhausted."
    )
  }

  private func stopCurrent(publishStopped: Bool) async {
    generation &+= 1
    cancelBackgroundTasks()
    let current = manager
    manager = nil
    await current?.stop()
    guard publishStopped else { return }
    let stopped = ServiceTunnelSnapshot(
      configured: tunnelID != nil && hasRuntimeKey(),
      enabled: enabled,
      helperAvailable: factory.helperAvailable(),
      tunnelID: tunnelID?.rawValue,
      lifecycle: .stopped,
      acceptsRemoteSubmissions: false,
      actionRequired: false
    )
    snapshot = stopped
    await publish(stopped)
  }

  private func cancelBackgroundTasks() {
    monitorTask?.cancel()
    restartTask?.cancel()
    monitorTask = nil
    restartTask = nil
  }

  private func loadStoredConfiguration() async {
    do {
      let rawID = try await settings.string(for: .tunnelID)
      let rawEnabled = try await settings.string(for: .tunnelEnabled)
      enabled = rawEnabled == "1"
      guard let rawID else {
        tunnelID = nil
        snapshot = .unconfigured(helperAvailable: factory.helperAvailable())
        return
      }
      tunnelID = try TunnelID(validating: rawID)
      let configured = hasRuntimeKey()
      snapshot = ServiceTunnelSnapshot(
        configured: configured,
        enabled: enabled,
        helperAvailable: factory.helperAvailable(),
        tunnelID: rawID,
        lifecycle: configured ? .stopped : .failed,
        acceptsRemoteSubmissions: false,
        actionRequired: !configured
      )
      if !configured {
        await publish(
          snapshot,
          degradation: "The stored Tunnel Runtime Key is unavailable."
        )
      }
    } catch {
      tunnelID = nil
      enabled = false
      snapshot = ServiceTunnelSnapshot(
        configured: false,
        enabled: false,
        helperAvailable: factory.helperAvailable(),
        tunnelID: nil,
        lifecycle: .failed,
        acceptsRemoteSubmissions: false,
        actionRequired: true
      )
      await publish(snapshot, degradation: "The stored Tunnel configuration is invalid.")
    }
  }

  private func persist(
    tunnelID: TunnelID,
    runtimeKey: Data,
    enabled: Bool
  ) async throws {
    let previousKey = try? secretStore.load(Self.runtimeKeyReference)
    let previousID = try? await settings.string(for: .tunnelID)
    let previousEnabled = try? await settings.string(for: .tunnelEnabled)
    do {
      try secretStore.store(runtimeKey, for: Self.runtimeKeyReference)
      try await settings.set(tunnelID.rawValue, for: .tunnelID)
      try await settings.set(enabled ? "1" : "0", for: .tunnelEnabled)
    } catch {
      if let previousKey {
        try? secretStore.store(previousKey, for: Self.runtimeKeyReference)
      } else {
        try? secretStore.remove(Self.runtimeKeyReference)
      }
      try? await settings.set(previousID ?? nil, for: .tunnelID)
      try? await settings.set(previousEnabled ?? nil, for: .tunnelEnabled)
      throw ServiceTunnelError.secretStoreUnavailable
    }
  }

  private func hasRuntimeKey() -> Bool {
    guard let data = try? secretStore.load(Self.runtimeKeyReference),
      let value = String(data: data, encoding: .utf8)
    else {
      return false
    }
    return (try? Self.validatedRuntimeKey(value)) != nil
  }

  private func publish(
    _ snapshot: ServiceTunnelSnapshot,
    degradation: String? = nil
  ) async {
    await runtimeStatus.updateTunnel(
      state: snapshot.lifecycle.rawValue,
      degradation: degradation
    )
  }

  private static func validatedRuntimeKey(_ value: String) throws -> Data {
    let bytes = Array(value.utf8)
    guard
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !bytes.isEmpty,
      bytes.count <= 16 * 1_024,
      bytes.allSatisfy({ (0x21...0x7E).contains($0) })
    else {
      throw ServiceTunnelError.invalidRuntimeKey
    }
    return Data(bytes)
  }

  private static func degradation(for snapshot: ServiceTunnelSnapshot) -> String? {
    switch snapshot.lifecycle {
    case .ready, .stopped, .starting, .authenticating, .connecting:
      nil
    case .degraded:
      "Secure MCP Tunnel remote readiness is degraded."
    case .failed:
      snapshot.actionRequired
        ? "Secure MCP Tunnel requires local action."
        : "Secure MCP Tunnel failed."
    }
  }

  private static func requiresLocalAction(_ error: any Error) -> Bool {
    if error is TunnelHelperError { return true }
    if let error = error as? TunnelManagerError {
      switch error {
      case .invalidRuntimeKey, .doctorFailed:
        return true
      case .alreadyRunning, .lifecycleBusy, .helperUnavailable, .launchFailed,
        .readinessTimedOut, .helperExited, .processTimedOut, .cleanupFailed, .stopped:
        return false
      }
    }
    return error is ServiceTunnelError
  }
}
