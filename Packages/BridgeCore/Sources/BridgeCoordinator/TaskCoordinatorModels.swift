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

/// A thread that has been created or resumed, but whose next turn has not started yet.
///
/// The coordinator persists this identity and atomically replaces any provisional
/// new-thread lock before allowing the runtime to call `turn/start`.
public struct PreparedTaskExecution: Codable, Equatable, Sendable {
  public let threadID: ThreadID
  public let turnGeneration: UInt64
  public let lockKeys: [String]

  public init(
    threadID: ThreadID,
    turnGeneration: UInt64,
    lockKeys: [String]
  ) {
    self.threadID = threadID
    self.turnGeneration = turnGeneration
    self.lockKeys = lockKeys
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

/// Opt-in durable startup protocol used by production runtimes.
///
/// Existing `TaskExecutionRuntime` conformers remain source compatible. A durable
/// runtime must keep the prepared app-server session private until `startPrepared`
/// is called, and must make `cancelPreparation` idempotent.
public protocol DurableTaskExecutionRuntime: TaskExecutionRuntime {
  func prepare(
    taskID: TaskID,
    submission: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) async throws -> PreparedTaskExecution

  func startPrepared(
    taskID: TaskID,
    submission: TaskSubmission,
    preparation: PreparedTaskExecution
  ) async throws -> TaskExecutionSession

  func cancelPreparation(taskID: TaskID) async
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

public struct TaskPipelineFinalizationReservation: Codable, Equatable, Sendable {
  public let taskID: TaskID
  public let binding: ExecutionBinding
  public let originalSequence: Int64
  public let reservationSequence: Int64
  public let reportReference: String
  public let reportDigest: String
  public let supervisorDecisionDigest: String

  package init(
    taskID: TaskID,
    binding: ExecutionBinding,
    originalSequence: Int64,
    reservationSequence: Int64,
    reportReference: String,
    reportDigest: String,
    supervisorDecisionDigest: String
  ) {
    self.taskID = taskID
    self.binding = binding
    self.originalSequence = originalSequence
    self.reservationSequence = reservationSequence
    self.reportReference = reportReference
    self.reportDigest = reportDigest
    self.supervisorDecisionDigest = supervisorDecisionDigest
  }
}

public struct TaskProjection: Equatable, Sendable {
  public let aggregate: TaskAggregate
  public let lastSequence: Int64

  public init(aggregate: TaskAggregate, lastSequence: Int64) {
    self.aggregate = aggregate
    self.lastSequence = lastSequence
  }
}

public struct TaskSubmissionResult: Equatable, Sendable {
  public let projection: TaskProjection
  public let reusedExistingTask: Bool

  public init(projection: TaskProjection, reusedExistingTask: Bool) {
    self.projection = projection
    self.reusedExistingTask = reusedExistingTask
  }
}

public struct TaskMutationResult: Equatable, Sendable {
  public let projection: TaskProjection
  public let operationID: OperationID

  public init(projection: TaskProjection, operationID: OperationID) {
    self.projection = projection
    self.operationID = operationID
  }
}

public struct TaskCoordinatorTurnMismatchError: Error, Equatable, Sendable {
  public init() {}
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
  case finalizationReservationMismatch
  case lockStateCorrupt(TaskID)
  case recoveryRequiresReconciliation(TaskPhase)
}
