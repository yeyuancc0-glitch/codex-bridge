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
  case semantic(TaskSemanticExecutionObservation)
  case turnCompleted
  case turnStopped
  case failed(reason: String)
}

public enum TaskExecutionReconciliationStatus: Equatable, Sendable {
  /// The runtime still owns the exact session and its observation stream.
  case attached
  /// A read-only wire snapshot reported the exact turn as running, but the runtime
  /// cannot reattach to its observation stream.
  case observedRunning
  case completed
  case interrupted
  case failed
  /// The registered project/root or execution policy no longer authorizes the session.
  case invalidated
}

public enum TaskExecutionReconciliationResult: Equatable, Sendable {
  case observed(binding: ExecutionBinding, status: TaskExecutionReconciliationStatus)
  case ambiguous
}

public enum TaskPlanStepStatus: String, Codable, Equatable, Sendable {
  case pending
  case inProgress
  case completed
}

public struct TaskPlanStepSnapshot: Codable, Equatable, Sendable {
  public let text: String
  public let status: TaskPlanStepStatus

  public init(text: String, status: TaskPlanStepStatus) throws {
    try TaskSemanticExecutionObservation.validateText(
      text,
      field: "planStep",
      maximumBytes: 4_096
    )
    self.text = text
    self.status = status
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      text: container.decode(String.self, forKey: .text),
      status: container.decode(TaskPlanStepStatus.self, forKey: .status)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case text
    case status
  }
}

public struct TaskPlanSnapshot: Codable, Equatable, Sendable {
  public let steps: [TaskPlanStepSnapshot]
  public let explanation: String?

  public init(steps: [TaskPlanStepSnapshot], explanation: String?) throws {
    guard !steps.isEmpty, steps.count <= 128 else {
      throw TaskSemanticExecutionObservationError.invalidPlan
    }
    if let explanation {
      try TaskSemanticExecutionObservation.validateText(
        explanation,
        field: "planExplanation",
        maximumBytes: 8_192,
        permitsEmpty: true
      )
    }
    self.steps = steps
    self.explanation = explanation
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      steps: container.decode([TaskPlanStepSnapshot].self, forKey: .steps),
      explanation: container.decodeIfPresent(String.self, forKey: .explanation)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case steps
    case explanation
  }
}

public enum TaskCommandCompletionStatus: String, Codable, Equatable, Sendable {
  case completed
  case failed
  case declined
}

public struct TaskCommandCompletion: Codable, Equatable, Sendable {
  public let itemID: String
  public let displayCommand: String
  public let exitCode: Int32?
  public let status: TaskCommandCompletionStatus

  public init(
    itemID: String,
    displayCommand: String,
    exitCode: Int32?,
    status: TaskCommandCompletionStatus
  ) throws {
    try TaskSemanticExecutionObservation.validateIdentifier(
      itemID,
      field: "itemID",
      maximumBytes: 256
    )
    try TaskSemanticExecutionObservation.validateText(
      displayCommand,
      field: "displayCommand",
      maximumBytes: 4_096
    )
    guard status != .completed || exitCode != nil else {
      throw TaskSemanticExecutionObservationError.invalidCommandCompletion
    }
    self.itemID = itemID
    self.displayCommand = displayCommand
    self.exitCode = exitCode
    self.status = status
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      itemID: container.decode(String.self, forKey: .itemID),
      displayCommand: container.decode(String.self, forKey: .displayCommand),
      exitCode: container.decodeIfPresent(Int32.self, forKey: .exitCode),
      status: container.decode(TaskCommandCompletionStatus.self, forKey: .status)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case itemID
    case displayCommand
    case exitCode
    case status
  }
}

public enum TaskFileChangeCompletionStatus: String, Codable, Equatable, Sendable {
  case completed
  case failed
  case declined
}

public struct TaskFileChangeCompletion: Codable, Equatable, Sendable {
  public let itemID: String
  public let changeCount: Int
  public let status: TaskFileChangeCompletionStatus

  public init(
    itemID: String,
    changeCount: Int,
    status: TaskFileChangeCompletionStatus
  ) throws {
    try TaskSemanticExecutionObservation.validateIdentifier(
      itemID,
      field: "itemID",
      maximumBytes: 256
    )
    guard (0...256).contains(changeCount) else {
      throw TaskSemanticExecutionObservationError.invalidFileChangeCompletion
    }
    self.itemID = itemID
    self.changeCount = changeCount
    self.status = status
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      itemID: container.decode(String.self, forKey: .itemID),
      changeCount: container.decode(Int.self, forKey: .changeCount),
      status: container.decode(TaskFileChangeCompletionStatus.self, forKey: .status)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case itemID
    case changeCount
    case status
  }
}

public enum TaskSemanticExecutionEvidence: Codable, Equatable, Sendable {
  case planChanged(TaskPlanSnapshot)
  case commandCompleted(TaskCommandCompletion)
  case fileChangeCompleted(TaskFileChangeCompletion)
}

public enum TaskSemanticExecutionObservationError: Error, Equatable, Sendable {
  case invalidIdentifier(String)
  case invalidPlan
  case invalidCommandCompletion
  case invalidFileChangeCompletion
  case encodedPayloadTooLarge(maximumBytes: Int)
}

public struct TaskSemanticExecutionObservation: Codable, Equatable, Sendable {
  public static let maximumEncodedBytes = 128 * 1_024

  public let sourceID: String
  public let evidence: TaskSemanticExecutionEvidence

  public init(sourceID: String, evidence: TaskSemanticExecutionEvidence) throws {
    try Self.validateIdentifier(sourceID, field: "sourceID", maximumBytes: 256)
    self.sourceID = sourceID
    self.evidence = evidence
    guard try Self.encodedByteCount(self) <= Self.maximumEncodedBytes else {
      throw TaskSemanticExecutionObservationError.encodedPayloadTooLarge(
        maximumBytes: Self.maximumEncodedBytes
      )
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      sourceID: container.decode(String.self, forKey: .sourceID),
      evidence: container.decode(TaskSemanticExecutionEvidence.self, forKey: .evidence)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case sourceID
    case evidence
  }

  fileprivate static func validateIdentifier(
    _ value: String,
    field: String,
    maximumBytes: Int
  ) throws {
    guard !value.isEmpty, value.utf8.count <= maximumBytes, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw TaskSemanticExecutionObservationError.invalidIdentifier(field)
    }
  }

  fileprivate static func validateText(
    _ value: String,
    field: String,
    maximumBytes: Int,
    permitsEmpty: Bool = false
  ) throws {
    let unsafeControl = value.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x09, 0x0A, 0x0D: false
      case 0..<0x20, 0x7F: true
      default: false
      }
    }
    guard permitsEmpty || !value.isEmpty, value.utf8.count <= maximumBytes, !unsafeControl else {
      throw TaskSemanticExecutionObservationError.invalidIdentifier(field)
    }
  }

  private static func encodedByteCount(_ value: Self) throws -> Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value).count
  }
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
  func approvalEvidence(
    taskID: TaskID,
    approvalID: ApprovalID
  ) async throws -> CodexApprovalEvidence?
  func finalizeApprovalResolution(
    taskID: TaskID,
    approvalID: ApprovalID,
    committed: Bool
  ) async
  func steer(taskID: TaskID, binding: ExecutionBinding, prompt: String) async throws
  func interrupt(taskID: TaskID, binding: ExecutionBinding) async throws
  func abortSession(taskID: TaskID, binding: ExecutionBinding) async throws
  func reconcile(
    taskID: TaskID,
    submission: TaskSubmission,
    binding: ExecutionBinding
  ) async throws -> TaskExecutionReconciliationResult
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
  case abortUnsupported
}

extension TaskExecutionRuntime {
  public func reconcile(
    taskID _: TaskID,
    submission _: TaskSubmission,
    binding _: ExecutionBinding
  ) async throws -> TaskExecutionReconciliationResult {
    .ambiguous
  }

  public func approvalEvidence(
    taskID _: TaskID,
    approvalID _: ApprovalID
  ) async throws -> CodexApprovalEvidence? {
    nil
  }

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

  public func abortSession(
    taskID _: TaskID,
    binding _: ExecutionBinding
  ) async throws {
    throw TaskExecutionRuntimeCompatibilityError.abortUnsupported
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

public struct TaskCoordinatorEventSequenceMismatchError: Error, Equatable, Sendable {
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
  case codexApprovalAuthorizationUnavailable
  case invalidSteerPrompt
  case invalidFailureReason
  case invalidFinalizationAuthorization
  case invalidReportReference
  case invalidRetentionLimit
  case finalizationReservationMismatch
  case lockStateCorrupt(TaskID)
  case recoveryRequiresReconciliation(TaskPhase)
}
