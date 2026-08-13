import BridgeDomain

public struct TaskPipelinePreStartContext: Equatable, Sendable {
  public let taskID: TaskID
  public let submission: TaskSubmission
  public let preparation: PreparedTaskExecution
  public let startIntentSequence: Int64

  public init(
    taskID: TaskID,
    submission: TaskSubmission,
    preparation: PreparedTaskExecution,
    startIntentSequence: Int64
  ) {
    self.taskID = taskID
    self.submission = submission
    self.preparation = preparation
    self.startIntentSequence = startIntentSequence
  }
}

public struct TaskPipelineStartedContext: Equatable, Sendable {
  public let preStart: TaskPipelinePreStartContext
  public let binding: ExecutionBinding

  public init(preStart: TaskPipelinePreStartContext, binding: ExecutionBinding) {
    self.preStart = preStart
    self.binding = binding
  }
}

public struct TaskPipelineVerifyingContext: Equatable, Sendable {
  public let projection: TaskProjection

  public init(projection: TaskProjection) {
    self.projection = projection
  }
}

public protocol TaskPipelineLifecycle: Sendable {
  func prepareForLegacyTurnStart(taskID: TaskID, submission: TaskSubmission) async throws
  func prepareForTurnStart(_ context: TaskPipelinePreStartContext) async throws
  func recordStartedTurn(_ context: TaskPipelineStartedContext) async throws
  func finalizeVerifyingTask(_ context: TaskPipelineVerifyingContext) async throws
  func discardTaskState(taskID: TaskID) async throws
}

public enum DeferredTaskPipelineLifecycleError: Error, Equatable, Sendable {
  case notInstalled
  case alreadyInstalled
}

/// Breaks the composition-root cycle between `TaskCoordinator` and a pipeline
/// finalizer through a single installation before task processing begins.
public actor DeferredTaskPipelineLifecycle: TaskPipelineLifecycle {
  private var target: (any TaskPipelineLifecycle)?

  public init() {}

  public func install(_ target: any TaskPipelineLifecycle) throws {
    guard self.target == nil else {
      throw DeferredTaskPipelineLifecycleError.alreadyInstalled
    }
    self.target = target
  }

  public func prepareForLegacyTurnStart(
    taskID: TaskID,
    submission: TaskSubmission
  ) async throws {
    try await requiredTarget().prepareForLegacyTurnStart(
      taskID: taskID,
      submission: submission
    )
  }

  public func prepareForTurnStart(_ context: TaskPipelinePreStartContext) async throws {
    try await requiredTarget().prepareForTurnStart(context)
  }

  public func recordStartedTurn(_ context: TaskPipelineStartedContext) async throws {
    try await requiredTarget().recordStartedTurn(context)
  }

  public func finalizeVerifyingTask(_ context: TaskPipelineVerifyingContext) async throws {
    try await requiredTarget().finalizeVerifyingTask(context)
  }

  public func discardTaskState(taskID: TaskID) async throws {
    try await requiredTarget().discardTaskState(taskID: taskID)
  }

  private func requiredTarget() throws -> any TaskPipelineLifecycle {
    guard let target else { throw DeferredTaskPipelineLifecycleError.notInstalled }
    return target
  }
}

extension TaskPipelineLifecycle {
  public func prepareForLegacyTurnStart(taskID _: TaskID, submission _: TaskSubmission) async throws
  {}

  public func prepareForTurnStart(_: TaskPipelinePreStartContext) async throws {}

  public func recordStartedTurn(_: TaskPipelineStartedContext) async throws {}

  public func finalizeVerifyingTask(_: TaskPipelineVerifyingContext) async throws {}

  public func discardTaskState(taskID _: TaskID) async throws {}
}
