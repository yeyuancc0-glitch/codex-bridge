import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import BridgeSupervisor
import Foundation

public actor ServiceExecutionCoordinator {
  struct ActiveAgentRun: Sendable {
    let providerID: String
    let installationID: String
    let providerSessionID: String?
    let providerRunID: String?
    let effectiveRunID: String
    let interrupt: @Sendable () async throws -> Void
    let steer: (@Sendable (String) async throws -> Void)?
    let shutdown: @Sendable () async -> Void
    let resolveApproval: (@Sendable (String, String) async throws -> Void)?
    var lastSequence: Int64? = nil
  }

  struct PendingAgentApproval: Sendable {
    let request: AgentApprovalRequest
    let createdAt: Date
  }

  let tasks: ServiceTaskManager
  let projects: ServiceProjectService
  let execution: ExecutionManager
  let supervision: ServiceSupervisorCoordinator
  let conversation: TaskConversationBuffer
  let conversationCoordinator: ServiceExecutionConversationCoordinator
  let agentEventProcessor: ServiceExecutionAgentEventProcessor
  let agentRunner: (any AgentTaskRunning)?
  let providerDisplayNameResolver: @Sendable (AgentProviderID) -> String
  var collectors: [TaskID: Task<Void, Never>] = [:]
  var activeAgentRuns: [TaskID: ActiveAgentRun] = [:]
  var pendingAgentApprovals: [String: PendingAgentApproval] = [:]
  var finishedRuns: Set<TaskID> = []
  private var startingTasks: Set<TaskID> = []
  var isShuttingDown = false
  let agentApprovalLifetime: TimeInterval = 5 * 60

  public init(
    tasks: ServiceTaskManager,
    projects: ServiceProjectService,
    execution: ExecutionManager,
    supervisor: SupervisorManager? = nil,
    conversation: TaskConversationBuffer? = nil,
    agentRunner: (any AgentTaskRunning)? = nil,
    providerDisplayNameResolver: @escaping @Sendable (AgentProviderID) -> String = {
      if $0 == .codex { return "Codex" }
      if $0 == .openCode { return "OpenCode" }
      if $0 == .deepSeekHarness { return "DeepSeek Harness" }
      if $0 == .antigravity { return "Antigravity" }
      return $0.rawValue
    }
  ) {
    let conversation = conversation ?? TaskConversationBuffer(tasks: tasks)
    self.tasks = tasks
    self.projects = projects
    self.execution = execution
    self.supervision = ServiceSupervisorCoordinator(
      tasks: tasks,
      execution: execution,
      supervisor: supervisor,
      conversation: conversation
    )
    self.conversation = conversation
    self.conversationCoordinator = ServiceExecutionConversationCoordinator(
      tasks: tasks,
      conversation: conversation
    )
    self.agentEventProcessor = ServiceExecutionAgentEventProcessor(
      tasks: tasks,
      projects: projects,
      conversation: conversation
    )
    self.agentRunner = agentRunner
    self.providerDisplayNameResolver = providerDisplayNameResolver
  }

  @discardableResult
  public func start(taskID: TaskID) async throws -> ExecutionBinding? {
    guard !isShuttingDown else {
      throw ExecutionServiceError.processUnavailable
    }
    guard collectors[taskID] == nil, activeAgentRuns[taskID] == nil,
      startingTasks.insert(taskID).inserted
    else {
      throw ExecutionServiceError.activeSession(taskID)
    }
    defer { startingTasks.remove(taskID) }
    guard let task = try await tasks.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    guard let project = try await projects.project(id: task.projectID) else {
      throw ExecutionServiceError.projectUnavailable(task.projectID)
    }
    guard task.providerID == serviceCodexProviderID else {
      try await startAgentTask(task, project: project)
      return nil
    }
    try ensureStartIsActive(taskID)

    await supervision.launch(task: task)
    let handle: ExecutionHandle
    do {
      handle = try await execution.start(try ExecutionRequest(task: task, project: project))
      try ensureStartIsActive(taskID)
      _ = try await tasks.markExecutionStarted(
        taskID: taskID,
        threadID: handle.binding.threadID,
        turnID: handle.binding.turnID
      )
      await conversation.appendUserMessage(taskID: taskID, content: task.prompt)
    } catch {
      await execution.stop(taskID: taskID)
      await supervision.stop(taskID: taskID)
      let conversationPersisted = await conversation.close(taskID: taskID)
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: conversationPersisted
          ? "execution_start_failed" : "conversation_persistence_failed",
        summary: conversationPersisted
          ? "Codex could not start the task."
          : "The task conversation could not be persisted."
      )
      throw error
    }

    let events = handle.events
    collectors[taskID] = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.consume(event, taskID: taskID)
      }
      await self?.collectorFinished(taskID)
    }
    return handle.binding
  }

  public func steer(
    taskID: TaskID,
    expectedTurnID: String,
    text: String
  ) async throws {
    if let run = activeAgentRuns[taskID] {
      guard run.effectiveRunID == expectedTurnID else {
        throw ExecutionServiceError.bindingMismatch
      }
      guard let steer = run.steer else {
        throw ExecutionServiceError.sessionUnavailable(taskID)
      }
      try await steer(text)
      await conversation.appendUserMessage(taskID: taskID, content: text)
      return
    }
    try await execution.steer(
      taskID: taskID,
      expectedTurnID: expectedTurnID,
      text: text
    )
    await conversation.appendUserMessage(taskID: taskID, content: text)
  }

  public func interrupt(
    taskID: TaskID,
    expectedTurnID: String? = nil
  ) async throws {
    try await execution.interrupt(taskID: taskID, expectedTurnID: expectedTurnID)
  }

  public func interruptAgent(taskID: TaskID, expectedRunID: String) async throws {
    guard let run = activeAgentRuns[taskID], run.effectiveRunID == expectedRunID else {
      throw ExecutionServiceError.threadMismatch(expectedRunID)
    }
    try await run.interrupt()
  }

  public func subscribeConversation(
    taskID: TaskID,
    limit: Int = 200
  ) async throws -> ConversationSubscription {
    try await conversationCoordinator.subscribe(taskID: taskID, limit: limit)
  }

  public func unsubscribeConversation(taskID: TaskID, subscriptionID: Int) async {
    await conversationCoordinator.unsubscribe(taskID: taskID, subscriptionID: subscriptionID)
  }

  public func conversationPage(
    taskID: TaskID,
    beforeMessageID: Int64? = nil,
    limit: Int = 200
  ) async throws -> [ServiceTaskMessageRecord] {
    try await conversationCoordinator.page(
      taskID: taskID,
      beforeMessageID: beforeMessageID,
      limit: limit
    )
  }

  public func liveConversationEntries(
    taskID: TaskID
  ) async throws -> [TaskConversationBuffer.Entry] {
    try await conversationCoordinator.liveEntries(taskID: taskID)
  }

  public func purgeConversation(taskID: TaskID) async {
    await conversationCoordinator.purge(taskID: taskID)
  }

  public func stop(
    taskID: TaskID,
    summary: String = "The local service stopped the task."
  ) async {
    startingTasks.remove(taskID)
    finishedRuns.insert(taskID)
    collectors.removeValue(forKey: taskID)?.cancel()
    await stopAgentRun(taskID: taskID)
    await execution.stop(taskID: taskID)
    await supervision.stop(taskID: taskID)
    if await conversation.close(taskID: taskID) {
      _ = try? await tasks.interrupt(taskID: taskID, summary: summary)
    } else {
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "conversation_persistence_failed",
        summary: "The task conversation could not be persisted."
      )
    }
  }

  public func shutdown() async {
    isShuttingDown = true
    finishedRuns.formUnion(startingTasks)
    finishedRuns.formUnion(activeAgentRuns.keys)
    startingTasks.removeAll(keepingCapacity: false)
    let executionTasks = collectors.values
    collectors.removeAll(keepingCapacity: false)
    pendingAgentApprovals.removeAll(keepingCapacity: false)
    for task in executionTasks { task.cancel() }
    await supervision.beginShutdown()
    let shutdowns = activeAgentRuns.values.map(\.shutdown)
    activeAgentRuns.removeAll(keepingCapacity: false)
    for shutdown in shutdowns {
      await shutdown()
    }
    await execution.shutdown()
    await supervision.shutdown()
    let failedConversationTasks = await conversation.closeAll()
    for taskID in failedConversationTasks {
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "conversation_persistence_failed",
        summary: "The task conversation could not be persisted before service shutdown."
      )
    }
  }

  private func stopAgentRun(taskID: TaskID) async {
    finishedRuns.insert(taskID)
    pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
    if let run = activeAgentRuns.removeValue(forKey: taskID) {
      await run.shutdown()
    }
  }

  func ensureStartIsActive(_ taskID: TaskID) throws {
    guard !isShuttingDown, startingTasks.contains(taskID), !finishedRuns.contains(taskID) else {
      throw CancellationError()
    }
  }

  func closeConversation(taskID: TaskID) async throws {
    guard await conversation.close(taskID: taskID) else {
      throw ExecutionServiceError.conversationPersistenceFailed
    }
  }

  static func persistenceFailureSummary(_ error: Error, provider: String = "Codex")
    -> String
  {
    let source = String(describing: error)
    let characters = source.unicodeScalars.map { scalar -> Character in
      switch scalar.value {
      case 0x09, 0x0A, 0x0D:
        Character(scalar)
      case 0..<0x20, 0x7F:
        " "
      default:
        Character(scalar)
      }
    }
    let sanitized = String(characters)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    let detail = sanitized.prefix(512)
    guard !detail.isEmpty else {
      return "The service could not persist \(provider) task progress."
    }
    return "The service could not persist \(provider) task progress: \(detail)"
  }

  func requiredTask(_ taskID: TaskID) async throws -> ServiceTaskRecord {
    guard let task = try await tasks.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    return task
  }

  private func collectorFinished(_ taskID: TaskID) {
    collectors[taskID] = nil
  }
}
