import BridgeAppModel
import BridgeCoordinator
import BridgeDomain
import BridgePresentation
import BridgeProjects
import BridgeSecurity
import BridgeTunnel
import Foundation

public enum DesktopBackendError: LocalizedError, Equatable, Sendable {
  case notReady
  case taskPipelineUnavailable
  case connectionNotConfigured
  case threadCatalogUnavailable
  case supportBundleUnavailable
  case invalidIdentifier
  case operationFailed

  public var errorDescription: String? {
    switch self {
    case .notReady:
      "本机状态仍在启动，请稍后重试。"
    case .taskPipelineUnavailable:
      "完整任务编排尚未接通；Bridge 不会启动不完整的任务。"
    case .connectionNotConfigured:
      "连接尚未配置，请先完成首次引导。"
    case .threadCatalogUnavailable:
      "Codex 线程读取尚未启用。"
    case .supportBundleUnavailable:
      "脱敏支持包导出尚未启用。"
    case .invalidIdentifier:
      "请求标识无效。"
    case .operationFailed:
      "本机操作未完成。"
    }
  }
}

actor LiveBridgeAppBackend: BridgeAppBackend {
  private let dataDirectoryURL: URL
  private let system: any DesktopSystemServing
  private let secretStore: any SecretStore
  private let bundleURL: URL
  private var continuations:
    [UUID: AsyncThrowingStream<BridgeAppStateSnapshot, Error>.Continuation] = [:]
  private var composition: DesktopComposition?
  private var bootstrapTask: Task<Void, Never>?
  private var connectionObserver: Task<Void, Never>?
  private var currentSnapshot: BridgeAppStateSnapshot
  private var revision: UInt64 = 1
  private var diagnostics: [LogEntryPresentation] = []
  private var isShuttingDown = false
  private var shutdownFinished = false
  private var activeOperations = 0
  private var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var compositionWaiters: [CheckedContinuation<Void, Error>] = []
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    dataDirectoryURL: URL,
    system: any DesktopSystemServing,
    secretStore: any SecretStore = KeychainSecretStore(),
    bundleURL: URL = Bundle.main.bundleURL
  ) {
    self.dataDirectoryURL = dataDirectoryURL
    self.system = system
    self.secretStore = secretStore
    self.bundleURL = bundleURL
    currentSnapshot = BridgeAppStateSnapshot(
      revision: revision,
      connectionState: .starting,
      presentation: .loading
    )
  }

  func stateUpdates() -> AsyncThrowingStream<BridgeAppStateSnapshot, Error> {
    let identifier = UUID()
    let pair = AsyncThrowingStream<BridgeAppStateSnapshot, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    continuations[identifier] = pair.continuation
    pair.continuation.yield(currentSnapshot)
    pair.continuation.onTermination = { @Sendable [weak self] _ in
      Task { await self?.removeContinuation(identifier) }
    }
    beginBootstrapIfNeeded()
    return pair.stream
  }

  func refresh(_ destination: BridgeNavigationDestination) async throws {
    _ = destination
    try beginOperation()
    defer { endOperation() }
    if composition == nil {
      publish(connectionState: .starting, presentation: .loading)
      beginBootstrapIfNeeded()
      return
    }
    try await publishCurrentFacts()
  }

  func submit(_ submission: BridgeAppTaskSubmission) throws -> BridgeAppTaskReceipt {
    _ = submission
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func steer(_ request: BridgeAppSteerRequest) throws {
    _ = request
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func interruptTask(_ taskID: String) throws {
    try Self.validateIdentifier(taskID)
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func authorizeTaskVerification(_ taskID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(taskID)
    let composition = try requireComposition()
    try await composition.verificationAuthorization.authorize(taskID: TaskID(rawValue: taskID))
    try checkRunning()
    appendDiagnostic("已签发一次性本机验证授权。", status: .ready)
    try await publishCurrentFacts()
  }

  func resolveLocalTask(
    requestID: String,
    decision: PresentationTaskDecision,
    model: String,
    effort: String
  ) throws {
    _ = (requestID, decision, model, effort)
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func resolveCodexApproval(_ resolution: BridgeApprovalResolution) throws {
    _ = resolution
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func connect() throws {
    throw DesktopBackendError.connectionNotConfigured
  }

  func disconnect() throws {
    throw DesktopBackendError.connectionNotConfigured
  }

  func testConnection() async throws {
    try beginOperation()
    defer { endOperation() }
    try await waitUntilReady()
    let composition = try requireComposition()
    try await composition.connectionRuntime.testConnection()
    try checkRunning()
    try await publishCurrentFacts()
  }

  func setReceivingPaused(_ paused: Bool) throws {
    _ = paused
    throw DesktopBackendError.connectionNotConfigured
  }

  func addProject() async throws {
    try beginOperation()
    defer { endOperation() }
    _ = try await registerSelectedProject()
  }

  func openProject(_ projectID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(projectID)
    let composition = try requireComposition()
    guard
      let project = try await composition.repository.project(id: ProjectID(rawValue: projectID))
    else {
      throw ProjectRegistryError.unknownProject
    }
    try checkRunning()
    try project.validateCurrentRoots()
    let opened = await system.open(URL(fileURLWithPath: project.primaryRoot.canonicalPath))
    try checkRunning()
    guard opened else { throw DesktopBackendError.operationFailed }
  }

  func readThreadHistory(_ threadID: String) throws {
    try Self.validateIdentifier(threadID)
    throw DesktopBackendError.threadCatalogUnavailable
  }

  func continueThread(_ threadID: String) throws {
    try Self.validateIdentifier(threadID)
    throw DesktopBackendError.threadCatalogUnavailable
  }

  func createTaskFromThread(_ threadID: String) throws {
    try Self.validateIdentifier(threadID)
    throw DesktopBackendError.taskPipelineUnavailable
  }

  func copyThreadID(_ threadID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(threadID)
    let copied = await system.copyToPasteboard(threadID)
    try checkRunning()
    guard copied else {
      throw DesktopBackendError.operationFailed
    }
  }

  func archiveSupervisorThread(_ threadID: String) throws {
    try Self.validateIdentifier(threadID)
    throw DesktopBackendError.threadCatalogUnavailable
  }

  func openThreadInCodex(_ threadID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(threadID)
    guard let url = Self.codexThreadURL(threadID) else {
      throw DesktopBackendError.operationFailed
    }
    let opened = await system.open(url)
    try checkRunning()
    guard opened else {
      throw DesktopBackendError.operationFailed
    }
  }

  func openTaskInCodex(_ taskID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(taskID)
    let composition = try requireComposition()
    let task = try await composition.coordinator.task(TaskID(rawValue: taskID))
    guard let threadID = task.aggregate.binding?.threadID.rawValue else {
      throw DesktopBackendError.operationFailed
    }
    try checkRunning()
    guard let url = Self.codexThreadURL(threadID) else {
      throw DesktopBackendError.operationFailed
    }
    let opened = await system.open(url)
    try checkRunning()
    guard opened else { throw DesktopBackendError.operationFailed }
  }

  func exportSupportBundle() throws {
    throw DesktopBackendError.supportBundleUnavailable
  }

  func updateSetting(key: String, enabled: Bool) throws {
    _ = (key, enabled)
    throw DesktopBackendError.operationFailed
  }

  func shutdown() async {
    if shutdownFinished { return }
    if isShuttingDown {
      await withCheckedContinuation { shutdownWaiters.append($0) }
      return
    }
    isShuttingDown = true
    failCompositionWaiters()
    let bootstrap = bootstrapTask
    bootstrap?.cancel()
    await bootstrap?.value
    bootstrapTask = nil
    if activeOperations > 0 {
      await withCheckedContinuation { operationDrainWaiters.append($0) }
    }
    connectionObserver?.cancel()
    await connectionObserver?.value
    connectionObserver = nil
    let composition = composition
    self.composition = nil
    await composition?.shutdown()
    let active = continuations.values
    continuations.removeAll(keepingCapacity: false)
    for continuation in active { continuation.finish() }
    shutdownFinished = true
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  func onboardingProject() async throws -> ProjectSummaryDTO? {
    try await waitUntilReady()
    let composition = try requireComposition()
    return try await composition.registry.summaries().first
  }

  func registerOnboardingProject() async throws -> ProjectSummaryDTO? {
    try beginOperation()
    defer { endOperation() }
    try await waitUntilReady()
    return try await registerSelectedProject()
  }

  func updateOnboardingProjectPolicy(
    projectID: ProjectID,
    policy: ProjectAccessPolicy
  ) async throws {
    try beginOperation()
    defer { endOperation() }
    try await waitUntilReady()
    let composition = try requireComposition()
    try await composition.registry.updateAccessPolicy(policy, for: projectID)
    try checkRunning()
    appendDiagnostic("已更新项目安全默认值。", status: .ready)
    try await publishCurrentFacts()
  }

  func configureOnboardingTransport(
    _ configuration: DesktopOnboardingTransportConfiguration
  ) async throws -> URL {
    try beginOperation()
    defer { endOperation() }
    try await waitUntilReady()
    let composition = try requireComposition()
    let localURL = try await composition.connectionRuntime.configure(configuration)
    try checkRunning()
    try await publishCurrentFacts()
    return localURL
  }

  func testOnboardingTransport() async throws {
    try beginOperation()
    defer { endOperation() }
    try await waitUntilReady()
    let composition = try requireComposition()
    try await composition.connectionRuntime.testConnection()
    try checkRunning()
    try await publishCurrentFacts()
  }

  func stopOnboardingTransport() async throws {
    try beginOperation()
    defer { endOperation() }
    try await waitUntilReady()
    let composition = try requireComposition()
    await composition.connectionRuntime.stop()
    try checkRunning()
    try await publishCurrentFacts()
  }

  private func beginBootstrapIfNeeded() {
    guard bootstrapTask == nil, composition == nil, !isShuttingDown else { return }
    bootstrapTask = Task { [weak self] in
      guard let self else { return }
      let failed: Bool
      do {
        let composition = try await DesktopComposition.make(
          dataDirectoryURL: self.dataDirectoryURL,
          system: self.system,
          secretStore: self.secretStore,
          bundleURL: self.bundleURL
        )
        try Task.checkCancellation()
        failed = await !self.finishBootstrap(composition)
      } catch is CancellationError {
        failed = false
      } catch {
        failed = true
      }
      await self.finishBootstrapTask(failed: failed)
    }
  }

  private func finishBootstrap(_ composition: DesktopComposition) async -> Bool {
    guard !isShuttingDown else { return false }
    self.composition = composition
    installConnectionObserver(composition.connectionRuntime)
    resumeCompositionWaiters()
    appendDiagnostic("本机持久化状态已就绪。", status: .ready)
    do {
      try await publishCurrentFacts()
      return true
    } catch {
      return false
    }
  }

  private func finishBootstrapTask(failed: Bool) {
    bootstrapTask = nil
    guard failed, !isShuttingDown else { return }
    failCompositionWaiters()
    publish(
      connectionState: .failed,
      presentation: DesktopPresentationProjection.failure(
        message: "Bridge 无法安全打开本机数据目录。请检查目录权限后重试。"
      )
    )
  }

  private func installConnectionObserver(_ runtime: DesktopConnectionRuntime) {
    connectionObserver?.cancel()
    connectionObserver = Task { [weak self, runtime] in
      let updates = await runtime.stateUpdates()
      var isInitial = true
      for await _ in updates {
        guard !Task.isCancelled else { return }
        if isInitial {
          isInitial = false
          continue
        }
        try? await self?.publishCurrentFacts()
      }
    }
  }

  private func publishCurrentFacts() async throws {
    try checkRunning()
    let composition = try requireComposition()
    let connection = await composition.connectionRuntime.health()
    try checkRunning()
    let projects = try await composition.repository.allProjects()
    try checkRunning()
    var tasks: [(TaskProjection, [TaskEventEnvelope])] = []
    let identifiers = try await composition.eventStore.recentlyUpdatedTaskIDs(limit: 500)
    try checkRunning()
    for taskID in identifiers {
      let projection = try await composition.coordinator.task(taskID)
      try checkRunning()
      let firstSequence = max(0, projection.lastSequence - 200)
      let events = try await composition.eventStore.events(
        for: taskID,
        afterSequence: firstSequence,
        limit: 200
      )
      try checkRunning()
      tasks.append((projection, events))
    }
    tasks.sort { lhs, rhs in
      (lhs.1.last?.createdAt ?? .distantPast) > (rhs.1.last?.createdAt ?? .distantPast)
    }
    publish(
      connectionState: Self.connectionState(connection),
      presentation: DesktopPresentationProjection.snapshot(
        projects: projects.sorted { $0.createdAt < $1.createdAt },
        tasks: tasks,
        diagnostics: diagnostics,
        connection: connection
      )
    )
  }

  private func publish(
    connectionState: BridgeAppConnectionState,
    presentation: BridgePresentationSnapshot
  ) {
    revision &+= 1
    currentSnapshot = BridgeAppStateSnapshot(
      revision: revision,
      connectionState: connectionState,
      presentation: presentation
    )
    for continuation in continuations.values {
      continuation.yield(currentSnapshot)
    }
  }

  private func appendDiagnostic(_ message: String, status: PresentationStatus) {
    diagnostics.append(
      LogEntryPresentation(
        id: UUID().uuidString,
        timestamp: Date(),
        source: "AppShell",
        severity: status,
        message: message
      )
    )
    if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
  }

  private func registerSelectedProject() async throws -> ProjectSummaryDTO? {
    let composition = try requireComposition()
    guard let directoryURL = await system.selectProjectDirectory() else { return nil }
    try checkRunning()
    let registration = try LocalProjectRegistration(
      name: directoryURL.lastPathComponent,
      rootURL: directoryURL
    )
    let project = try await composition.registry.register(local: registration)
    try checkRunning()
    appendDiagnostic("已注册一个本机项目。", status: .ready)
    try await publishCurrentFacts()
    return project
  }

  private func waitUntilReady() async throws {
    try checkRunning()
    if composition != nil { return }
    beginBootstrapIfNeeded()
    try await withCheckedThrowingContinuation { continuation in
      if composition != nil {
        continuation.resume()
      } else if isShuttingDown {
        continuation.resume(throwing: DesktopBackendError.notReady)
      } else {
        compositionWaiters.append(continuation)
      }
    }
    try checkRunning()
  }

  private func resumeCompositionWaiters() {
    let waiters = compositionWaiters
    compositionWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  private func failCompositionWaiters() {
    let waiters = compositionWaiters
    compositionWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume(throwing: DesktopBackendError.notReady) }
  }

  private func requireComposition() throws -> DesktopComposition {
    try checkRunning()
    guard let composition else { throw DesktopBackendError.notReady }
    return composition
  }

  private func beginOperation() throws {
    try checkRunning()
    activeOperations += 1
  }

  private func endOperation() {
    activeOperations -= 1
    guard activeOperations == 0 else { return }
    let waiters = operationDrainWaiters
    operationDrainWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  private func checkRunning() throws {
    if isShuttingDown { throw CancellationError() }
  }

  private func removeContinuation(_ identifier: UUID) {
    continuations[identifier] = nil
  }

  private static func validateIdentifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DesktopBackendError.invalidIdentifier
    }
  }

  private static func codexThreadURL(_ threadID: String) -> URL? {
    var components = URLComponents()
    components.scheme = "codex"
    components.host = "threads"
    components.path = "/\(threadID)"
    return components.url
  }

  static func connectionState(_ health: DesktopTransportHealth) -> BridgeAppConnectionState {
    if health.acceptsRemoteSubmissions { return .ready }
    return switch health.lifecycle {
    case .stopped: .stopped
    case .starting: .starting
    case .authenticating: .authenticating
    case .connecting: .connecting
    case .ready: .degraded
    case .degraded: .degraded
    case .failed: .failed
    }
  }
}
