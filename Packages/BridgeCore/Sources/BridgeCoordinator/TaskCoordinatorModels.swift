import BridgeDomain
import Foundation

public enum TaskAdmissionDecision: Equatable, Sendable {
  case start
  case requireLocalApproval
}

public protocol TaskAdmissionPolicy: Sendable {
  func decision(for submission: TaskSubmission) async throws -> TaskAdmissionDecision
}

public struct TaskExecutionSession: Sendable {
  public let binding: ExecutionBinding
  public let observations: AsyncStream<TaskExecutionObservation>

  public init(
    binding: ExecutionBinding,
    observations: AsyncStream<TaskExecutionObservation>
  ) {
    self.binding = binding
    self.observations = observations
  }
}

public enum TaskExecutionObservation: Equatable, Sendable {
  case codexApprovalRequested(ApprovalID)
  case turnCompleted
  case turnStopped
  case failed(reason: String)
}

public protocol TaskExecutionRuntime: Sendable {
  func lockKeys(for submission: TaskSubmission) async throws -> [String]
  func lockKeys(
    for submission: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) async throws -> [String]
  func start(taskID: TaskID, submission: TaskSubmission) async throws -> TaskExecutionSession
  func start(
    taskID: TaskID,
    submission: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) async throws -> TaskExecutionSession
  func resolveApproval(taskID: TaskID, approvalID: ApprovalID, approved: Bool) async throws
  func finalizeApprovalResolution(
    taskID: TaskID,
    approvalID: ApprovalID,
    committed: Bool
  ) async
  func steer(taskID: TaskID, binding: ExecutionBinding, prompt: String) async throws
  func interrupt(taskID: TaskID, binding: ExecutionBinding) async throws
}

public enum TaskExecutionRuntimeCompatibilityError: Error, Equatable, Sendable {
  case steerUnsupported
}

extension TaskExecutionRuntime {
  public func lockKeys(
    for submission: TaskSubmission,
    previousBinding _: ExecutionBinding?
  ) async throws -> [String] {
    try await lockKeys(for: submission)
  }

  public func start(
    taskID: TaskID,
    submission: TaskSubmission,
    previousBinding _: ExecutionBinding?
  ) async throws -> TaskExecutionSession {
    try await start(taskID: taskID, submission: submission)
  }

  public func finalizeApprovalResolution(
    taskID _: TaskID,
    approvalID _: ApprovalID,
    committed _: Bool
  ) async {}

  public func steer(
    taskID _: TaskID,
    binding _: ExecutionBinding,
    prompt _: String
  ) async throws {
    throw TaskExecutionRuntimeCompatibilityError.steerUnsupported
  }
}

public enum TaskFinalizationAuthorization: Equatable, Sendable {
  case supervisorFinalAccept(decisionID: String)
  case userOverride(reason: String)
}

public struct TaskProjection: Equatable, Sendable {
  public let aggregate: TaskAggregate
  public let lastSequence: Int64

  public init(aggregate: TaskAggregate, lastSequence: Int64) {
    self.aggregate = aggregate
    self.lastSequence = lastSequence
  }
}

public enum TaskCoordinatorError: Error, Equatable, Sendable {
  case invalidOrigin
  case submissionTooLarge
  case unknownTask(TaskID)
  case corruptTask(TaskID)
  case projectReadDenied
  case projectWriteDenied
  case projectNetworkDenied
  case unsupportedPermissionMode(String)
  case executionUnavailable(TaskID)
  case invalidApprovalIdentifier
  case invalidSteerPrompt
  case invalidFailureReason
  case invalidFinalizationAuthorization
  case invalidReportReference
  case lockStateCorrupt(TaskID)
  case recoveryRequiresReconciliation(TaskPhase)
}
