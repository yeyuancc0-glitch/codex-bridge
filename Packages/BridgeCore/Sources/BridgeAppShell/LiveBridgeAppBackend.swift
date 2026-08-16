import BridgeAppModel
import BridgeApplication
import BridgeCoordinator
import BridgeDomain
import BridgeMCP
import BridgePersistence
import BridgePipeline
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
  case approvalEvidenceUnavailable
  case invalidProjectPolicy
  case projectHasActiveTasks
  case invalidIdentifier
  case operationFailed

  public var errorDescription: String? {
    switch self {
    case .notReady:
      "本机状态仍在启动，请稍后重试。"
    case .taskPipelineUnavailable:
      "此入口尚未提供完整任务契约；Bridge 不会启动信息不完整的任务。"
    case .connectionNotConfigured:
      "连接尚未配置，请先完成首次引导。"
    case .threadCatalogUnavailable:
      "Codex 线程读取尚未启用。"
    case .supportBundleUnavailable:
      "脱敏支持包未能安全导出。"
    case .approvalEvidenceUnavailable:
      "审批缺少权威命令、文件与影响证据；当前只能拒绝。"
    case .invalidProjectPolicy:
      "读取权限只能设为允许或不允许。"
    case .projectHasActiveTasks:
      "项目仍有关联的活动任务；请先完成、中断或暂停这些任务。"
    case .invalidIdentifier:
      "请求标识无效。"
    case .operationFailed:
      "本机操作未完成。"
    }
  }
}

actor LiveBridgeAppBackend: BridgeAppBackend {
  private enum EvidenceCache: Sendable {
    case loading(DesktopTaskEvidenceIdentity)
    case ready(DesktopTaskEvidenceIdentity, DesktopTaskEvidenceValues)
    case unavailable(DesktopTaskEvidenceIdentity, String)
  }

  private static let maximumVisibleHistoryEntries = 500
  private static let maximumVisibleThreads = 500
  private static let maximumActiveTasks = 2_048
  private static let threadPageLimit = 100
  private let dataDirectoryURL: URL
  private let system: any DesktopSystemServing
  private let secretStore: any SecretStore
  private let bundleURL: URL
  private let catalog: (any CodexCatalogQuerying)?
  private var continuations:
    [UUID: AsyncThrowingStream<BridgeAppStateSnapshot, Error>.Continuation] = [:]
  private var composition: DesktopComposition?
  private var bootstrapTask: Task<Void, Never>?
  private var connectionObserver: Task<Void, Never>?
  private var taskObserver: Task<Void, Never>?
  private var currentSnapshot: BridgeAppStateSnapshot
  private var revision: UInt64 = 1
  private var factsRequest: UInt64 = 0
  private var diagnostics: [LogEntryPresentation] = []
  private var operatorState = DesktopOperatorState()
  private var taskEvidenceCache: EvidenceCache?
  private var isShuttingDown = false
  private var shutdownFinished = false
  private var activeOperations = 0
  private var isRunningCatalogOperation = false
  private var isLoadingTaskEvidence = false
  private var pendingTaskEvidenceID: TaskID?
  private var isExportingSupportBundle = false
  private var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var compositionWaiters: [CheckedContinuation<Void, Error>] = []
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    dataDirectoryURL: URL,
    system: any DesktopSystemServing,
    secretStore: any SecretStore = KeychainSecretStore(),
    bundleURL: URL = Bundle.main.bundleURL,
    catalog: (any CodexCatalogQuerying)? = nil
  ) {
    self.dataDirectoryURL = dataDirectoryURL
    self.system = system
    self.secretStore = secretStore
    self.bundleURL = bundleURL
    self.catalog = catalog
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
    try beginOperation()
    defer { endOperation() }
    if composition == nil {
      publish(connectionState: .starting, presentation: .loading)
      beginBootstrapIfNeeded()
      return
    }
    if destination == .threads {
      try await refreshThreads(projectID: operatorState.selectedProjectID)
      return
    }
    if destination == .overview {
      try await refreshAccountRateLimits()
      return
    }
    try await publishCurrentFacts()
  }

  func submit(_ submission: BridgeAppTaskSubmission) async throws -> BridgeAppTaskReceipt {
    try beginOperation()
    defer { endOperation() }
    guard DesktopSupervisorAvailability.productionReviewAvailable else {
      throw DesktopBackendError.taskPipelineUnavailable
    }
    try Self.validateIdentifier(submission.requestID)
    try Self.validateIdentifier(submission.projectID)
    try Self.validateIdentifier(submission.goal)
    let criteria = submission.acceptanceCriteria.filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !criteria.isEmpty else { throw DesktopBackendError.operationFailed }
    let composition = try requireComposition()
    let task = TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: submission.requestID),
      projectID: ProjectID(rawValue: submission.projectID),
      thread: submission.threadID.map { .existing(ThreadID(rawValue: $0)) } ?? .new,
      execution: ExecutionOptions(
        model: submission.model,
        effort: submission.effort,
        permissionMode: submission.permissionMode,
        networkAccess: submission.networkAllowed
      ),
      supervisor: SupervisorOptions(
        enabled: true,
        model: LocalReadOnlyTaskPolicy.supervisorModelID,
        effort: "medium"
      ),
      contract: TaskContract(goal: submission.goal, acceptanceCriteria: criteria)
    )
    let receipt = try await composition.application.submitLocalTask(
      task,
      deadline: ContinuousClock.now.advanced(by: .seconds(20))
    )
    try checkRunning()
    return BridgeAppTaskReceipt(
      taskID: receipt.taskID,
      reusedExistingTask: receipt.reusedExistingTask
    )
  }

  func steer(_ request: BridgeAppSteerRequest) async throws {
    try beginOperation()
    defer { endOperation() }
    let composition = try requireComposition()
    _ = try await composition.application.steerTask(
      taskID: request.taskID,
      expectedTurnID: request.expectedTurnID,
      input: request.input,
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    try checkRunning()
    try await publishCurrentFacts()
  }

  func interruptTask(_ taskID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(taskID)
    let composition = try requireComposition()
    let task = try await composition.coordinator.task(TaskID(rawValue: taskID))
    guard let turnID = task.aggregate.binding?.turnID.rawValue else {
      throw DesktopBackendError.operationFailed
    }
    _ = try await composition.application.interruptTask(
      taskID: taskID,
      expectedTurnID: turnID,
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    try checkRunning()
    try await publishCurrentFacts()
  }

  func suspendAmbiguousTask(_ taskID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(taskID)
    let composition = try requireComposition()
    _ = try await composition.coordinator.suspendAmbiguousRecovery(
      taskID: TaskID(rawValue: taskID)
    )
    try checkRunning()
    appendDiagnostic("已将恢复状态不确定的任务标记为暂停并释放锁。", status: .paused)
    try await publishCurrentFacts()
  }

  func markSupervisorActionApplied(taskID: String, actionID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(taskID)
    try Self.validateIdentifier(actionID)
    let composition = try requireComposition()
    let actions = try await composition.supervisionLedger.ambiguousActions(
      limit: DurableSupervisionLedger.maximumQueryLimit
    )
    guard actions.contains(where: { $0.id == actionID && $0.scope.taskID.rawValue == taskID })
    else {
      throw DesktopBackendError.operationFailed
    }
    _ = try await composition.supervisionLedger.markActionApplied(id: actionID)
    try checkRunning()
    appendDiagnostic("操作员已确认 Supervisor 动作的外部结果，动作标记为已应用。", status: .ready)
    try await publishCurrentFacts()
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
  ) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(requestID)
    let composition = try requireComposition()
    let taskID = TaskID(rawValue: requestID)
    let task = try await composition.coordinator.task(taskID)
    guard task.aggregate.phase == .awaitingLocalApproval,
      task.aggregate.submission.execution.model == model,
      task.aggregate.submission.execution.effort == effort
    else {
      throw DesktopBackendError.operationFailed
    }
    switch decision {
    case .start:
      _ = try await composition.coordinator.resolveLocalApproval(
        taskID: taskID,
        approved: true
      )
    case .reject:
      _ = try await composition.coordinator.resolveLocalApproval(
        taskID: taskID,
        approved: false
      )
    case .runReadOnly:
      throw DesktopBackendError.operationFailed
    }
    try checkRunning()
    appendDiagnostic("已持久化本机任务决定。", status: .ready)
    try await publishCurrentFacts()
  }

  func resolveCodexApproval(_ resolution: BridgeApprovalResolution) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(resolution.approvalID)
    guard resolution.decision == .deny, resolution.capability == nil else {
      throw DesktopBackendError.approvalEvidenceUnavailable
    }
    let composition = try requireComposition()
    guard let rawTaskID = resolution.taskID, let rawThreadID = resolution.threadID,
      let rawTurnID = resolution.turnID
    else { throw DesktopBackendError.operationFailed }
    try Self.validateIdentifier(rawTaskID)
    try Self.validateIdentifier(rawThreadID)
    try Self.validateIdentifier(rawTurnID)
    let taskID = TaskID(rawValue: rawTaskID)
    let task = try await composition.coordinator.task(taskID)
    guard task.aggregate.binding?.threadID.rawValue == rawThreadID,
      task.aggregate.binding?.turnID.rawValue == rawTurnID,
      task.aggregate.pendingApprovalIDs.contains(ApprovalID(rawValue: resolution.approvalID))
    else { throw DesktopBackendError.operationFailed }
    _ = try await composition.coordinator.resolveCodexApproval(
      taskID: taskID,
      approvalID: ApprovalID(rawValue: resolution.approvalID),
      approved: false
    )
    try checkRunning()
    appendDiagnostic("已拒绝一项缺少原子执行保证的 Codex 审批。", status: .blocked)
    try await publishCurrentFacts()
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

  func setReceivingPaused(_ paused: Bool) async throws {
    try beginOperation()
    defer { endOperation() }
    try await waitUntilReady()
    let composition = try requireComposition()
    try await composition.lifecycleCoordinator.updateReceivingPaused(paused)
    try checkRunning()
    appendDiagnostic(
      paused ? "已暂停新的远程任务提交；本地任务继续运行。" : "已恢复新的远程任务提交。",
      status: paused ? .paused : .ready
    )
    try await publishCurrentFacts()
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

  func updateProjectAccessPolicy(
    projectID: String,
    read: ProjectPermissionPresentation,
    write: ProjectPermissionPresentation,
    network: ProjectPermissionPresentation
  ) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(projectID)
    guard read != .requiresLocalApproval else {
      throw DesktopBackendError.invalidProjectPolicy
    }
    let composition = try requireComposition()
    let policy = ProjectAccessPolicy(
      read: Self.projectPermission(read),
      write: Self.projectPermission(write),
      network: Self.projectPermission(network)
    )
    try await composition.registry.updateAccessPolicy(
      policy,
      for: ProjectID(rawValue: projectID)
    )
    try checkRunning()
    appendDiagnostic("已更新项目访问策略。", status: .ready)
    try await publishCurrentFacts()
  }

  func reconnectProject(_ projectID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(projectID)
    let composition = try requireComposition()
    let id = ProjectID(rawValue: projectID)
    guard let project = try await composition.repository.project(id: id) else {
      throw ProjectRegistryError.unknownProject
    }
    guard (try? project.validateCurrentRoots()) == nil else {
      throw DesktopBackendError.operationFailed
    }
    guard
      let directory = await system.selectReplacementProjectDirectory(projectName: project.name)
    else { return }
    try checkRunning()
    let lease: TaskProjectRemovalLease
    do {
      lease = try await composition.projectMutationGate.acquireRemoval(for: id)
    } catch TaskProjectMutationGateError.submissionsInProgress {
      throw DesktopBackendError.projectHasActiveTasks
    } catch {
      throw DesktopBackendError.operationFailed
    }
    do {
      try await requireNoActiveTasks(for: id, composition: composition)
      try await composition.registry.rebindSingleRoot(
        for: id,
        confirmedRootURL: directory
      )
      await composition.projectMutationGate.releaseRemoval(lease)
    } catch {
      await composition.projectMutationGate.releaseRemoval(lease)
      throw error
    }
    try checkRunning()
    operatorState.rebindProjectSelection(projectID)
    appendDiagnostic("已重新验证项目卷身份；本机文件未被修改。", status: .ready)
    try await publishCurrentFacts()
  }

  func removeProject(_ projectID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(projectID)
    let composition = try requireComposition()
    let id = ProjectID(rawValue: projectID)
    let lease: TaskProjectRemovalLease
    do {
      lease = try await composition.projectMutationGate.acquireRemoval(for: id)
    } catch TaskProjectMutationGateError.submissionsInProgress {
      throw DesktopBackendError.projectHasActiveTasks
    } catch {
      throw DesktopBackendError.operationFailed
    }
    do {
      try await requireNoActiveTasks(for: id, composition: composition)
      try await composition.registry.unregister(id)
      await composition.projectMutationGate.releaseRemoval(lease)
    } catch {
      await composition.projectMutationGate.releaseRemoval(lease)
      throw error
    }
    try checkRunning()
    operatorState.removeProjectSelection(projectID)
    appendDiagnostic("已从 Bridge 注册表移除项目；本机文件未被删除。", status: .ready)
    try await publishCurrentFacts()
  }

  func selectThreadProject(_ projectID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(projectID)
    try await refreshThreads(projectID: projectID)
  }

  func loadMoreThreads() async throws {
    try beginOperation()
    defer { endOperation() }
    try beginCatalogOperation()
    defer { endCatalogOperation() }
    guard case .ready(let current) = operatorState.threads,
      !current.isLoadingMore,
      let cursor = current.nextCursor,
      !cursor.isEmpty,
      current.threads.count < Self.maximumVisibleThreads
    else { throw DesktopBackendError.operationFailed }
    operatorState.threadGeneration &+= 1
    let generation = operatorState.threadGeneration
    operatorState.threads = .ready(
      DesktopThreadCatalogPage(
        projectID: current.projectID,
        projectName: current.projectName,
        threads: current.threads,
        nextCursor: current.nextCursor,
        isLoadingMore: true,
        isTruncated: current.isTruncated
      )
    )
    try await publishCurrentFacts()
    do {
      let composition = try requireComposition()
      let page = try await composition.application.listThreads(
        projectID: current.projectID,
        cursor: cursor,
        limit: Self.threadPageLimit,
        search: nil,
        deadline: ContinuousClock.now.advanced(by: .seconds(20))
      )
      try checkRunning()
      guard generation == operatorState.threadGeneration,
        operatorState.selectedProjectID == current.projectID,
        page.nextCursor != cursor
      else { throw DesktopBackendError.operationFailed }
      let merged = try Self.mergedThreads(current.threads, page.threads)
      let visible = Array(merged.prefix(Self.maximumVisibleThreads))
      let truncated =
        merged.count > visible.count
        || (page.nextCursor != nil && visible.count >= Self.maximumVisibleThreads)
      operatorState.threads = .ready(
        DesktopThreadCatalogPage(
          projectID: current.projectID,
          projectName: current.projectName,
          threads: visible,
          nextCursor: truncated ? nil : page.nextCursor,
          isLoadingMore: false,
          isTruncated: truncated
        )
      )
      try await publishCurrentFacts()
    } catch {
      if generation == operatorState.threadGeneration {
        operatorState.threads = .ready(current)
        try? await publishCurrentFacts()
      }
      throw error
    }
  }

  func readThreadHistory(_ threadID: String) throws {
    try Self.validateIdentifier(threadID)
    throw DesktopBackendError.threadCatalogUnavailable
  }

  func readThreadHistory(projectID: String, threadID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try beginCatalogOperation()
    defer { endCatalogOperation() }
    try Self.validateIdentifier(projectID)
    try Self.validateIdentifier(threadID)
    guard case .ready(let catalog) = operatorState.threads,
      catalog.projectID == projectID,
      catalog.threads.contains(where: { $0.threadID == threadID })
    else { throw DesktopBackendError.operationFailed }
    let generation = operatorState.beginHistory()
    try await publishCurrentFacts()
    do {
      let composition = try requireComposition()
      let page = try await composition.application.readThread(
        projectID: projectID,
        threadID: threadID,
        detail: .full,
        cursor: nil,
        limit: Self.threadPageLimit,
        deadline: ContinuousClock.now.advanced(by: .seconds(20))
      )
      try checkRunning()
      guard generation == operatorState.historyGeneration,
        page.thread.threadID == threadID,
        operatorState.selectedProjectID == projectID
      else { return }
      operatorState.history = .ready(
        DesktopThreadHistoryPage(
          projectID: projectID,
          thread: page.thread,
          entries: page.entries,
          nextCursor: page.nextCursor,
          isLoadingMore: false,
          isTruncated: false
        )
      )
      try await publishCurrentFacts()
    } catch {
      if generation == operatorState.historyGeneration {
        operatorState.history = .failed("Codex Thread 历史读取失败；未显示未经核验的内容。")
        try? await publishCurrentFacts()
      }
      throw error
    }
  }

  func loadMoreThreadHistory() async throws {
    try beginOperation()
    defer { endOperation() }
    try beginCatalogOperation()
    defer { endCatalogOperation() }
    guard case .ready(let current)? = operatorState.history,
      !current.isLoadingMore,
      let cursor = current.nextCursor,
      !cursor.isEmpty,
      current.entries.count < Self.maximumVisibleHistoryEntries
    else { throw DesktopBackendError.operationFailed }
    operatorState.historyGeneration &+= 1
    let generation = operatorState.historyGeneration
    operatorState.history = .ready(
      DesktopThreadHistoryPage(
        projectID: current.projectID,
        thread: current.thread,
        entries: current.entries,
        nextCursor: current.nextCursor,
        isLoadingMore: true,
        isTruncated: current.isTruncated
      )
    )
    try await publishCurrentFacts()
    do {
      let composition = try requireComposition()
      let page = try await composition.application.readThread(
        projectID: current.projectID,
        threadID: current.thread.threadID,
        detail: .full,
        cursor: cursor,
        limit: Self.threadPageLimit,
        deadline: ContinuousClock.now.advanced(by: .seconds(20))
      )
      try checkRunning()
      guard generation == operatorState.historyGeneration,
        page.thread.threadID == current.thread.threadID,
        page.nextCursor != cursor,
        operatorState.selectedProjectID == current.projectID
      else { throw DesktopBackendError.operationFailed }
      let merged = current.entries + page.entries
      let visible = Array(merged.prefix(Self.maximumVisibleHistoryEntries))
      let truncated =
        merged.count > visible.count
        || (page.nextCursor != nil && visible.count >= Self.maximumVisibleHistoryEntries)
      operatorState.history = .ready(
        DesktopThreadHistoryPage(
          projectID: current.projectID,
          thread: page.thread,
          entries: visible,
          nextCursor: truncated ? nil : page.nextCursor,
          isLoadingMore: false,
          isTruncated: truncated
        )
      )
      try await publishCurrentFacts()
    } catch {
      if generation == operatorState.historyGeneration {
        operatorState.history = .ready(current)
        try? await publishCurrentFacts()
      }
      throw error
    }
  }

  func continueThread(_ threadID: String) async throws {
    try Self.validateIdentifier(threadID)
    try await prepareReadOnlyTask(
      projectID: operatorState.selectedProjectID,
      threadID: threadID
    )
  }

  func createTaskFromThread(_ threadID: String) async throws {
    try Self.validateIdentifier(threadID)
    try await prepareReadOnlyTask(
      projectID: operatorState.selectedProjectID,
      threadID: threadID
    )
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

  func openThreadInCodex(projectID: String, threadID: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try beginCatalogOperation()
    defer { endCatalogOperation() }
    try Self.validateIdentifier(projectID)
    try Self.validateIdentifier(threadID)
    let composition = try requireComposition()
    let receipt = try await composition.application.openInCodex(
      projectID: projectID,
      threadID: threadID,
      deadline: ContinuousClock.now.advanced(by: .seconds(20))
    )
    try checkRunning()
    guard receipt.opened, receipt.projectID == projectID, receipt.threadID == threadID else {
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

  func loadTaskEvidence(_ taskIDValue: String) async throws {
    try beginOperation()
    defer { endOperation() }
    try Self.validateIdentifier(taskIDValue)
    let requestedTaskID = TaskID(rawValue: taskIDValue)
    guard !isLoadingTaskEvidence else {
      pendingTaskEvidenceID = requestedTaskID
      return
    }
    isLoadingTaskEvidence = true
    defer { isLoadingTaskEvidence = false }
    let composition = try requireComposition()
    var taskID: TaskID? = requestedTaskID
    while let currentTaskID = taskID {
      pendingTaskEvidenceID = nil
      try await loadAndPublishTaskEvidence(
        currentTaskID,
        composition: composition
      )
      taskID = pendingTaskEvidenceID
    }
  }

  private func loadAndPublishTaskEvidence(
    _ taskID: TaskID,
    composition: DesktopComposition
  ) async throws {
    let initial = try await composition.coordinator.task(taskID)
    let requestIdentity = DesktopTaskEvidenceIdentity(initial)
    try checkRunning()
    taskEvidenceCache = .loading(requestIdentity)
    try await publishCurrentFacts()

    do {
      let result = try await loadTaskEvidence(
        taskID: taskID,
        composition: composition
      )
      guard Self.evidenceByteCount(result.values) <= 2 * 1_024 * 1_024 else {
        throw DesktopBackendError.operationFailed
      }
      taskEvidenceCache = .ready(result.identity, result.values)
    } catch is CancellationError {
      taskEvidenceCache = nil
      throw CancellationError()
    } catch {
      let current = try? await composition.coordinator.task(taskID)
      if let current, DesktopTaskEvidenceIdentity(current) == requestIdentity {
        taskEvidenceCache = .unavailable(
          requestIdentity,
          "持久证据未通过完整性核验；任务事实保持不变。"
        )
      } else {
        taskEvidenceCache = nil
      }
    }
    try checkRunning()
    try await publishCurrentFacts()
  }

  func prepareReadOnlyTask(projectID requestedProjectID: String?, threadID: String?) async throws {
    try beginOperation()
    defer { endOperation() }
    try beginCatalogOperation()
    defer { endCatalogOperation() }
    if let requestedProjectID { try Self.validateIdentifier(requestedProjectID) }
    if let threadID { try Self.validateIdentifier(threadID) }
    switch operatorState.composer {
    case .loading?, .ready?: throw DesktopBackendError.operationFailed
    case .none, .notLoaded?, .failed?: break
    }
    operatorState.composer = .loading
    try await publishCurrentFacts()
    do {
      let composition = try requireComposition()
      let projects = try await composition.repository.allProjects()
        .filter { $0.accessPolicy.read != .denied }
        .sorted { $0.createdAt < $1.createdAt }
      try checkRunning()
      guard let projectID = requestedProjectID ?? projects.first?.id.rawValue,
        projects.contains(where: { $0.id.rawValue == projectID })
      else { throw DesktopBackendError.operationFailed }
      if let threadID {
        _ = try await composition.application.readThread(
          projectID: projectID,
          threadID: threadID,
          detail: .summary,
          cursor: nil,
          limit: 1,
          deadline: ContinuousClock.now.advanced(by: .seconds(20))
        )
      }
      let models = try await composition.application.listModels(
        deadline: ContinuousClock.now.advanced(by: .seconds(20))
      ).models
      try checkRunning()
      guard !models.isEmpty else { throw DesktopBackendError.operationFailed }
      operatorState.composer = .ready(
        DesktopLocalTaskComposer(
          requestID: Self.localRequestID(),
          projectID: projectID,
          threadID: threadID,
          models: models,
          isSubmitting: false,
          submittedDraft: nil
        )
      )
      try await publishCurrentFacts()
    } catch {
      operatorState.composer = .failed("无法读取当前 Codex 模型目录；未创建本机任务。")
      try? await publishCurrentFacts()
      throw error
    }
  }

  func dismissReadOnlyTask() async throws {
    try beginOperation()
    defer { endOperation() }
    guard case .ready(let composer)? = operatorState.composer,
      !composer.isSubmitting
    else { throw DesktopBackendError.operationFailed }
    operatorState.composer = nil
    try await publishCurrentFacts()
  }

  func submitReadOnlyTask(_ draft: ReadOnlyTaskDraftPresentation) async throws {
    try beginOperation()
    defer { endOperation() }
    try beginCatalogOperation()
    defer { endCatalogOperation() }
    guard case .ready(let composer)? = operatorState.composer,
      !composer.isSubmitting,
      composer.requestID == draft.requestID
    else { throw DesktopBackendError.operationFailed }
    let requestID =
      composer.submittedDraft == nil || composer.submittedDraft == draft
      ? composer.requestID : Self.localRequestID()
    let attemptDraft = Self.draft(draft, requestID: requestID)
    let submission = try Self.readOnlySubmission(draft, requestID: requestID, composer: composer)
    operatorState.composer = .ready(
      DesktopLocalTaskComposer(
        requestID: requestID,
        projectID: draft.projectID,
        threadID: draft.threadID,
        models: composer.models,
        isSubmitting: true,
        submittedDraft: attemptDraft
      )
    )
    try await publishCurrentFacts()
    do {
      let composition = try requireComposition()
      if let threadID = draft.threadID {
        _ = try await composition.application.readThread(
          projectID: draft.projectID,
          threadID: threadID,
          detail: .summary,
          cursor: nil,
          limit: 1,
          deadline: ContinuousClock.now.advanced(by: .seconds(20))
        )
      }
      _ = try await composition.application.submitLocalTask(
        submission,
        deadline: ContinuousClock.now.advanced(by: .seconds(20))
      )
      try checkRunning()
      operatorState.composer = nil
      appendDiagnostic("已持久化一个本机只读任务。", status: .ready)
      try await publishCurrentFacts()
    } catch {
      operatorState.composer = .ready(
        DesktopLocalTaskComposer(
          requestID: requestID,
          projectID: draft.projectID,
          threadID: draft.threadID,
          models: composer.models,
          isSubmitting: false,
          submittedDraft: attemptDraft
        )
      )
      try? await publishCurrentFacts()
      throw error
    }
  }

  func exportSupportBundle() async throws {
    try beginOperation()
    guard !isExportingSupportBundle else {
      endOperation()
      throw DesktopBackendError.operationFailed
    }
    isExportingSupportBundle = true
    defer {
      isExportingSupportBundle = false
      endOperation()
    }
    let result: DesktopSupportBundleSaveResult
    do {
      try await publishCurrentFacts()
      result = try await saveSupportBundle()
    } catch {
      try? await publishCurrentFacts(canExportSupportBundleOverride: true)
      throw error
    }
    if result == .saved {
      appendDiagnostic("已导出脱敏支持包。", status: .ready)
    }
    try await publishCurrentFacts(canExportSupportBundleOverride: true)
    guard result == .saved || result == .cancelled else {
      throw DesktopBackendError.supportBundleUnavailable
    }
  }

  private func saveSupportBundle() async throws -> DesktopSupportBundleSaveResult {
    let composition = try requireComposition()
    let connection = await composition.connectionRuntime.health()
    guard await system.supportsSupportBundleExport else {
      throw DesktopBackendError.supportBundleUnavailable
    }
    try checkRunning()
    let projects = try await composition.repository.allProjects()
    try checkRunning()
    let recentTasks = try await composition.eventStore.recentlyUpdatedTaskIDs(limit: 500)
    try checkRunning()
    let data = try DesktopSupportBundle.build(
      diagnostics: diagnostics,
      connection: connection,
      projectCount: projects.count,
      recentTaskCount: recentTasks.count
    )
    let result = await system.saveSupportBundle(
      data,
      suggestedFileName: "CodexBridge-Support.json"
    )
    try checkRunning()
    return result
  }

  func updateSetting(key: String, enabled: Bool) async throws {
    try beginOperation()
    defer { endOperation() }
    try await waitUntilReady()
    let lifecycle = try requireComposition().lifecycleCoordinator
    switch key {
    case "launch-at-login":
      try await system.setLaunchAtLoginEnabled(enabled)
    case "task-notifications":
      try await lifecycle.updateNotificationsEnabled(enabled)
    case "idle-sleep-prevention":
      try await lifecycle.updateIdleSleepEnabled(enabled)
    default:
      throw DesktopBackendError.operationFailed
    }
    try checkRunning()
    try await publishCurrentFacts()
  }

  func updateRetentionPolicy(
    eventDays: Int,
    metadataDays: Int,
    recentTaskLimit: Int?,
    expectedRevision: Int64
  ) async throws {
    try beginOperation()
    defer { endOperation() }
    try await waitUntilReady()
    let composition = try requireComposition()
    _ = try await composition.eventStore.updateTaskRetentionPolicy(
      eventDays: eventDays,
      metadataDays: metadataDays,
      recentTaskLimit: recentTaskLimit,
      expectedRevision: expectedRevision
    )
    _ = try await composition.retentionCoordinator.run()
    try checkRunning()
    try await publishCurrentFacts()
  }

  private func refreshAccountRateLimits() async throws {
    try beginCatalogOperation()
    defer { endCatalogOperation() }
    let composition = try requireComposition()
    operatorState.rateLimits = .loading
    try await publishCurrentFacts()
    do {
      let summary = try await composition.application.accountRateLimits(
        deadline: ContinuousClock.now.advanced(by: .seconds(20))
      )
      try checkRunning()
      operatorState.rateLimits = .ready(summary)
      try await publishCurrentFacts()
    } catch {
      operatorState.rateLimits = .failed("Codex 账号限额暂不可用")
      try? await publishCurrentFacts()
      throw error
    }
  }

  private func requireNoActiveTasks(
    for projectID: ProjectID,
    composition: DesktopComposition
  ) async throws {
    var cursor: TaskID?
    var inspected = 0
    while inspected < Self.maximumActiveTasks {
      let remaining = Self.maximumActiveTasks - inspected
      let page = try await composition.eventStore.taskIDsWithActiveSnapshots(
        afterTaskID: cursor,
        limit: min(500, remaining)
      )
      for taskID in page {
        let task = try await composition.coordinator.task(taskID)
        if task.aggregate.submission.projectID == projectID {
          throw DesktopBackendError.projectHasActiveTasks
        }
      }
      inspected += page.count
      guard page.count == min(500, remaining) else { return }
      cursor = page.last
    }
    let overflow = try await composition.eventStore.taskIDsWithActiveSnapshots(
      afterTaskID: cursor,
      limit: 1
    )
    guard overflow.isEmpty else { throw DesktopBackendError.projectHasActiveTasks }
  }

  func shutdown() async {
    if shutdownFinished { return }
    if isShuttingDown {
      await withCheckedContinuation { shutdownWaiters.append($0) }
      return
    }
    isShuttingDown = true
    failCompositionWaiters()
    await composition?.mcpRuntime.shutdown()
    await composition?.lifecycleCoordinator.closeRemoteAdmissions()
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
    taskObserver?.cancel()
    await taskObserver?.value
    taskObserver = nil
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
      var createdComposition: DesktopComposition?
      do {
        let composition = try await DesktopComposition.make(
          dataDirectoryURL: self.dataDirectoryURL,
          system: self.system,
          secretStore: self.secretStore,
          bundleURL: self.bundleURL,
          catalog: self.catalog
        )
        createdComposition = composition
        try Task.checkCancellation()
        let installed = await self.finishBootstrap(composition)
        if !installed, await self.isShuttingDown {
          await composition.shutdown()
          failed = false
        } else {
          failed = !installed
        }
      } catch is CancellationError {
        await createdComposition?.shutdown()
        failed = false
      } catch {
        await createdComposition?.shutdown()
        failed = true
      }
      await self.finishBootstrapTask(failed: failed)
    }
  }

  private func finishBootstrap(_ composition: DesktopComposition) async -> Bool {
    guard !isShuttingDown else { return false }
    self.composition = composition
    installConnectionObserver(composition.connectionRuntime)
    await installTaskObserver(composition.eventStore)
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

  private func installTaskObserver(_ eventStore: EventStore) async {
    taskObserver?.cancel()
    let updates = await eventStore.taskChanges()
    taskObserver = Task { [weak self, updates] in
      for await _ in updates {
        guard !Task.isCancelled else { return }
        try? await self?.publishCurrentFacts()
      }
    }
  }

  private func refreshThreads(projectID requestedProjectID: String?) async throws {
    try beginCatalogOperation()
    defer { endCatalogOperation() }
    let composition = try requireComposition()
    let projects = try await composition.repository.allProjects()
      .filter { $0.accessPolicy.read != .denied }
      .sorted { $0.createdAt < $1.createdAt }
    try checkRunning()
    let selectedProjectID =
      requestedProjectID ?? operatorState.selectedProjectID
      ?? projects.first?.id.rawValue
    guard let selectedProjectID else {
      operatorState.selectedProjectID = nil
      operatorState.threads = .notLoaded
      operatorState.history = nil
      try await publishCurrentFacts()
      return
    }
    guard let project = projects.first(where: { $0.id.rawValue == selectedProjectID }) else {
      throw DesktopBackendError.operationFailed
    }
    let generation = operatorState.selectProject(selectedProjectID)
    try await publishCurrentFacts()
    do {
      let page = try await composition.application.listThreads(
        projectID: selectedProjectID,
        cursor: nil,
        limit: Self.threadPageLimit,
        search: nil,
        deadline: ContinuousClock.now.advanced(by: .seconds(20))
      )
      try checkRunning()
      guard generation == operatorState.threadGeneration,
        operatorState.selectedProjectID == selectedProjectID
      else { return }
      let threads = try Self.mergedThreads([], page.threads)
      operatorState.threads = .ready(
        DesktopThreadCatalogPage(
          projectID: selectedProjectID,
          projectName: project.name,
          threads: threads,
          nextCursor: page.nextCursor,
          isLoadingMore: false,
          isTruncated: false
        )
      )
      try await publishCurrentFacts()
    } catch {
      if generation == operatorState.threadGeneration {
        operatorState.threads = .failed("Codex Thread 目录读取失败；请检查登录状态后重试。")
        try? await publishCurrentFacts()
      }
      throw error
    }
  }

  private static func mergedThreads(
    _ existing: [MCPThreadSummary],
    _ additional: [MCPThreadSummary]
  ) throws -> [MCPThreadSummary] {
    var seen = Set(existing.map(\.threadID))
    var result = existing
    for thread in additional {
      guard seen.insert(thread.threadID).inserted else {
        throw DesktopBackendError.operationFailed
      }
      result.append(thread)
    }
    return result
  }

  static func readOnlySubmission(
    _ draft: ReadOnlyTaskDraftPresentation,
    requestID: String,
    composer: DesktopLocalTaskComposer
  ) throws -> TaskSubmission {
    try validateIdentifier(requestID)
    try validateIdentifier(draft.projectID)
    try validateIdentifier(draft.executionModel)
    try validateIdentifier(draft.executionEffort)
    if draft.supervisorEnabled {
      try validateIdentifier(draft.supervisorModel)
      try validateIdentifier(draft.supervisorEffort)
    }
    if let threadID = draft.threadID {
      try validateIdentifier(threadID)
    }
    guard draft.threadID == composer.threadID else {
      throw DesktopBackendError.operationFailed
    }
    if composer.threadID != nil, draft.projectID != composer.projectID {
      throw DesktopBackendError.operationFailed
    }
    let goal = draft.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    let criteria = draft.acceptanceCriteria.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard !goal.isEmpty, goal.utf8.count <= 32 * 1_024,
      (1...100).contains(criteria.count),
      criteria.allSatisfy({ $0.utf8.count <= 4 * 1_024 }),
      let execution = composer.models.first(where: { $0.modelID == draft.executionModel }),
      execution.reasoningEfforts.contains(draft.executionEffort)
    else { throw DesktopBackendError.operationFailed }
    if draft.supervisorEnabled {
      guard let supervisor = composer.models.first(where: { $0.modelID == draft.supervisorModel })
      else { throw DesktopBackendError.operationFailed }
      guard
        LocalReadOnlyTaskPolicy.isLunaModel(
          id: supervisor.modelID,
          displayName: supervisor.displayName
        ), supervisor.reasoningEfforts.contains(draft.supervisorEffort)
      else {
        throw DesktopBackendError.operationFailed
      }
    }
    return TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: requestID),
      projectID: ProjectID(rawValue: draft.projectID),
      thread: draft.threadID.map { .existing(ThreadID(rawValue: $0)) } ?? .new,
      execution: ExecutionOptions(
        model: draft.executionModel,
        effort: draft.executionEffort,
        permissionMode: "read-only",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(
        enabled: draft.supervisorEnabled,
        model: draft.supervisorModel,
        effort: draft.supervisorEffort,
        deterministicFallbackAuthorized: !draft.supervisorEnabled
      ),
      contract: TaskContract(goal: goal, acceptanceCriteria: criteria)
    )
  }

  private static func draft(
    _ source: ReadOnlyTaskDraftPresentation,
    requestID: String
  ) -> ReadOnlyTaskDraftPresentation {
    ReadOnlyTaskDraftPresentation(
      requestID: requestID,
      projectID: source.projectID,
      threadID: source.threadID,
      goal: source.goal,
      acceptanceCriteria: source.acceptanceCriteria,
      executionModel: source.executionModel,
      executionEffort: source.executionEffort,
      supervisorEnabled: source.supervisorEnabled,
      supervisorModel: source.supervisorModel,
      supervisorEffort: source.supervisorEffort
    )
  }

  private static func localRequestID() -> String {
    "local_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
  }

  private func publishCurrentFacts(
    canExportSupportBundleOverride: Bool? = nil
  ) async throws {
    try checkRunning()
    factsRequest &+= 1
    let request = factsRequest
    let composition = try requireComposition()
    let connection = await composition.connectionRuntime.health()
    let canExportSupportBundle = await system.supportsSupportBundleExport
    let launchAtLoginStatus = await system.launchAtLoginStatus
    let lifecyclePreferences = try await composition.lifecycleCoordinator.preferences()
    let retentionPolicy = try await composition.eventStore.taskRetentionPolicy()
    try checkRunning()
    let projects = try await composition.repository.allProjects()
    try checkRunning()
    var tasks: [(TaskProjection, [TaskEventEnvelope])] = []
    var evidenceByTaskID: [TaskID: DesktopTaskEvidenceValues] = [:]
    var evidenceStateByTaskID: [TaskID: TaskEvidenceLoadPresentation] = [:]
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
      let key = DesktopTaskEvidenceIdentity(projection)
      switch taskEvidenceCache {
      case .loading(let cachedKey) where cachedKey == key:
        evidenceStateByTaskID[taskID] = .loading
      case .ready(let cachedKey, let values) where cachedKey == key:
        evidenceByTaskID[taskID] = values
        evidenceStateByTaskID[taskID] = .available
      case .unavailable(let cachedKey, let message) where cachedKey == key:
        evidenceStateByTaskID[taskID] = .unavailable(message)
      default:
        evidenceStateByTaskID[taskID] = .notLoaded
      }
    }
    tasks.sort { lhs, rhs in
      (lhs.1.last?.createdAt ?? .distantPast) > (rhs.1.last?.createdAt ?? .distantPast)
    }
    guard request == factsRequest else { return }
    let orderedProjects = projects.sorted { $0.createdAt < $1.createdAt }
    publish(
      connectionState: Self.connectionState(connection),
      presentation: DesktopPresentationProjection.snapshot(
        projects: orderedProjects,
        tasks: tasks,
        evidenceByTaskID: evidenceByTaskID,
        evidenceStateByTaskID: evidenceStateByTaskID,
        diagnostics: diagnostics,
        connection: connection,
        receivingPaused: lifecyclePreferences.receivingPaused,
        operatorState: operatorState,
        canExportSupportBundle: canExportSupportBundleOverride
          ?? (canExportSupportBundle && !isExportingSupportBundle),
        lifecyclePreferences: lifecyclePreferences,
        launchAtLoginStatus: launchAtLoginStatus,
        retentionPolicy: RetentionPolicyPresentation(
          eventDays: retentionPolicy.eventDays,
          metadataDays: retentionPolicy.metadataDays,
          recentTaskLimit: retentionPolicy.recentTaskLimit,
          revision: retentionPolicy.revision
        )
      ),
      pendingSheet: DesktopPresentationProjection.pendingSheet(
        projects: orderedProjects,
        tasks: tasks
      )
    )
  }

  private func loadTaskEvidence(
    taskID: TaskID,
    composition: DesktopComposition
  ) async throws -> DesktopTaskEvidenceProjectionResult {
    for attempt in 0..<2 {
      do {
        return try await composition.taskEvidence.projectBound(
          taskID: taskID,
          deadline: ContinuousClock.now.advanced(by: .seconds(3))
        )
      } catch DesktopTaskEvidenceProjectionError.scopeMismatch where attempt == 0 {
        try Task.checkCancellation()
        try checkRunning()
      }
    }
    throw DesktopTaskEvidenceProjectionError.scopeMismatch
  }

  private static func evidenceByteCount(_ values: DesktopTaskEvidenceValues) -> Int {
    let strings =
      values.commands + values.changedFiles
      + [values.diffSummary, values.supervisionSummary, values.verificationSummary].compactMap {
        $0
      }
      + values.ambiguousSupervisorActions.map(\.instruction)
    return strings.reduce(into: 0) { total, value in
      let (next, overflow) = total.addingReportingOverflow(value.utf8.count)
      total = overflow ? Int.max : next
    }
  }

  private func publish(
    connectionState: BridgeAppConnectionState,
    presentation: BridgePresentationSnapshot,
    pendingSheet: PresentedBridgeSheet? = nil
  ) {
    revision &+= 1
    currentSnapshot = BridgeAppStateSnapshot(
      revision: revision,
      connectionState: connectionState,
      presentation: presentation,
      pendingSheet: pendingSheet
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

  private func beginCatalogOperation() throws {
    guard !isRunningCatalogOperation else { throw DesktopBackendError.operationFailed }
    isRunningCatalogOperation = true
  }

  private func endCatalogOperation() {
    isRunningCatalogOperation = false
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

  private static func projectPermission(
    _ permission: ProjectPermissionPresentation
  ) -> ProjectPermission {
    switch permission {
    case .denied: .denied
    case .requiresLocalApproval: .requiresLocalApproval
    case .allowed: .allowed
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
