import BridgeDomain
import Foundation

public actor ServiceTaskManager {
  private let store: SimpleServiceStore
  private let makeTaskID: @Sendable () -> TaskID
  private let now: @Sendable () -> Date

  public init(
    store: SimpleServiceStore,
    makeTaskID: @escaping @Sendable () -> TaskID = {
      TaskID(rawValue: "tsk-" + UUID().uuidString.lowercased())
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.makeTaskID = makeTaskID
    self.now = now
  }

  public func submit(
    _ request: ServiceTaskRequest,
    taskID requestedTaskID: TaskID? = nil
  ) async throws -> ServiceTaskCreationResult {
    let date = now()
    let state = try ServiceTaskState(status: .awaitingLocalApproval)
    let task = try ServiceTaskRecord(
      id: requestedTaskID ?? makeTaskID(),
      projectID: request.projectID,
      source: request.source,
      sourceClientID: request.sourceClientID,
      clientRequestID: request.clientRequestID,
      prompt: request.prompt,
      requestedThreadID: request.requestedThreadID,
      executionModel: request.executionModel,
      executionEffort: request.executionEffort,
      supervisorModel: request.supervisorModel,
      supervisorEffort: request.supervisorEffort,
      permissionMode: request.permissionMode,
      networkAllowed: request.networkAllowed,
      accessMode: request.accessMode,
      fastMode: request.fastMode,
      state: state,
      createdAt: date,
      updatedAt: date
    )
    return try await store.createTask(
      task,
      event: ServiceTaskEventDraft(
        kind: .taskCreated,
        summary: "The task was accepted.",
        createdAt: date
      )
    )
  }

  @discardableResult
  public func begin(taskID: TaskID) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(
        status: .starting,
        supervisorStatus: try await supervisorStartStatus(taskID: taskID)
      ),
      eventKind: .executionStarting,
      summary: "The task was accepted and Codex execution is starting."
    )
  }

  @discardableResult
  public func markExecutionStarted(
    taskID: TaskID,
    threadID: String,
    turnID: String
  ) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(
        codexThreadID: .set(threadID),
        codexTurnID: .set(turnID),
        status: .running
      ),
      eventKind: .executionStarted,
      summary: "Codex started the task turn."
    )
  }

  @discardableResult
  public func updatePlan(taskID: TaskID, currentStep: String) async throws
    -> ServiceTaskRecord
  {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(currentStep: .set(currentStep)),
      eventKind: .planUpdated,
      summary: "Codex updated the current task step."
    )
  }

  @discardableResult
  public func recordChangedFiles(
    taskID: TaskID,
    relativePaths: [String],
    summary: String = "Codex reported project file changes."
  ) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(changedFilesToAppend: relativePaths),
      eventKind: .fileChanged,
      summary: summary
    )
  }

  @discardableResult
  public func recordCommandCompletion(
    taskID: TaskID,
    summary: String
  ) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(),
      eventKind: .commandCompleted,
      summary: summary
    )
  }

  @discardableResult
  public func markWaitingForCodexApproval(taskID: TaskID) async throws
    -> ServiceTaskRecord
  {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(status: .waitingForCodexApproval),
      eventKind: .approvalRequested,
      summary: "Codex is waiting for a local approval decision."
    )
  }

  @discardableResult
  public func resumeAfterCodexApproval(taskID: TaskID, approved: Bool) async throws
    -> ServiceTaskRecord
  {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(status: .running),
      eventKind: .approvalResolved,
      summary: approved
        ? "The local user approved the Codex request."
        : "The local user denied the Codex request; Codex may continue with a safer path."
    )
  }

  @discardableResult
  public func complete(
    taskID: TaskID,
    resultSummary: String,
    changedFiles: [String]
  ) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(
        status: .completed,
        changedFiles: changedFiles,
        resultSummary: .set(resultSummary),
        failureCode: .set(nil)
      ),
      eventKind: .taskCompleted,
      summary: "Codex completed the task."
    )
  }

  @discardableResult
  public func fail(
    taskID: TaskID,
    failureCode: String,
    summary: String
  ) async throws -> ServiceTaskRecord {
    let task = try await requiredTask(id: taskID)
    let supervisorStatus: ServiceSupervisorStatus =
      task.state.supervisorStatus == .disabled ? .disabled : .degraded
    return try await mutate(
      taskID: taskID,
      patch: StatePatch(
        status: .failed,
        supervisorStatus: supervisorStatus,
        resultSummary: .set(summary),
        failureCode: .set(failureCode)
      ),
      eventKind: .taskFailed,
      summary: summary
    )
  }

  @discardableResult
  public func interrupt(taskID: TaskID, summary: String) async throws -> ServiceTaskRecord {
    try await mutate(
      taskID: taskID,
      patch: StatePatch(status: .interrupted),
      eventKind: .taskInterrupted,
      summary: summary
    )
  }

  @discardableResult
  public func updateSupervisor(
    taskID: TaskID,
    status: ServiceSupervisorStatus,
    summary: String?
  ) async throws -> ServiceTaskRecord {
    let eventKind: ServiceTaskEventKind
    switch status {
    case .starting, .running:
      eventKind = .supervisorStarted
    case .degraded:
      eventKind = .supervisorDegraded
    case .completed, .disabled:
      eventKind = .supervisorDecision
    }
    return try await mutate(
      taskID: taskID,
      patch: StatePatch(
        supervisorStatus: status,
        supervisorSummary: .set(summary)
      ),
      eventKind: eventKind,
      summary: summary ?? "The Supervisor state changed to \(status.rawValue)."
    )
  }

  @discardableResult
  public func recoverIncompleteTasks() async throws -> [ServiceTaskRecord] {
    try await store.markIncompleteTasksUnknown(at: now())
  }

  public func task(id: TaskID) async throws -> ServiceTaskRecord? {
    try await store.task(id: id)
  }

  public func tasks(projectID: ProjectID? = nil, limit: Int = 100) async throws
    -> [ServiceTaskRecord]
  {
    try await store.tasks(projectID: projectID, limit: limit)
  }

  public func events(taskID: TaskID, limit: Int = 100) async throws
    -> [ServiceTaskEventRecord]
  {
    try await store.events(taskID: taskID, limit: limit)
  }

  public func upsertTaskMessage(
    taskID: TaskID,
    key: String,
    role: ServiceTaskMessageRole,
    content: String,
    kind: ServiceTaskMessageKind = .agent,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil
  ) async throws {
    try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: key,
        role: role,
        content: content,
        createdAt: now(),
        kind: kind,
        toolName: toolName,
        toolStatus: toolStatus,
        toolArguments: toolArguments
      ),
      taskID: taskID
    )
  }

  public func messages(
    taskID: TaskID,
    beforeMessageID: Int64? = nil,
    limit: Int = 200
  ) async throws -> [ServiceTaskMessageRecord] {
    try await store.taskMessages(
      taskID: taskID,
      beforeMessageID: beforeMessageID,
      limit: limit
    )
  }

  public func remove(taskID: TaskID) async throws {
    guard let task = try await store.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    guard task.state.status.isTerminal || task.state.status == .unknown else {
      throw ServiceStoreError.invalidArgument("task.removeActive")
    }
    try await store.removeTask(id: taskID)
  }

  public func activeWriteTask(projectID: ProjectID) async throws -> ServiceTaskRecord? {
    try await store.activeWriteTask(projectID: projectID)
  }

  private func mutate(
    taskID: TaskID,
    patch: StatePatch,
    eventKind: ServiceTaskEventKind,
    summary: String
  ) async throws -> ServiceTaskRecord {
    let current = try await requiredTask(id: taskID)
    let date = now()
    let state = try Self.apply(patch, to: current.state)
    let updated = try current.replacingState(state, updatedAt: date)
    try await store.updateTask(
      updated,
      event: ServiceTaskEventDraft(
        kind: eventKind,
        summary: summary,
        createdAt: date
      )
    )
    return updated
  }

  private func requiredTask(id: TaskID) async throws -> ServiceTaskRecord {
    guard let task = try await store.task(id: id) else {
      throw ServiceStoreError.unknownTask(id)
    }
    return task
  }

  private func supervisorStartStatus(taskID: TaskID) async throws -> ServiceSupervisorStatus {
    let task = try await requiredTask(id: taskID)
    return task.supervisorModel == nil ? .disabled : .starting
  }

  private static func apply(
    _ patch: StatePatch,
    to current: ServiceTaskState
  ) throws -> ServiceTaskState {
    try ServiceTaskState(
      codexThreadID: patch.codexThreadID.applying(to: current.codexThreadID),
      codexTurnID: patch.codexTurnID.applying(to: current.codexTurnID),
      status: patch.status ?? current.status,
      supervisorStatus: patch.supervisorStatus ?? current.supervisorStatus,
      currentStep: patch.currentStep.applying(to: current.currentStep),
      changedFiles: patch.changedFiles
        ?? Array(Set(current.changedFiles + patch.changedFilesToAppend)).sorted(),
      resultSummary: patch.resultSummary.applying(to: current.resultSummary),
      supervisorSummary: patch.supervisorSummary.applying(to: current.supervisorSummary),
      failureCode: patch.failureCode.applying(to: current.failureCode)
    )
  }
}

private struct StatePatch: Sendable {
  var codexThreadID: OptionalUpdate<String> = .keep
  var codexTurnID: OptionalUpdate<String> = .keep
  var status: ServiceTaskStatus?
  var supervisorStatus: ServiceSupervisorStatus?
  var currentStep: OptionalUpdate<String> = .keep
  var changedFiles: [String]?
  var changedFilesToAppend: [String] = []
  var resultSummary: OptionalUpdate<String> = .keep
  var supervisorSummary: OptionalUpdate<String> = .keep
  var failureCode: OptionalUpdate<String> = .keep
}

private enum OptionalUpdate<Value: Sendable>: Sendable {
  case keep
  case set(Value?)

  func applying(to current: Value?) -> Value? {
    switch self {
    case .keep:
      current
    case .set(let value):
      value
    }
  }
}
