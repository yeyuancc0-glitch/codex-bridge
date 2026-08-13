import Foundation

public struct TaskSubmission: Codable, Equatable, Sendable {
  public let schemaVersion: UInt16
  public let idempotencyKey: IdempotencyKey
  public let projectID: ProjectID
  public let thread: ThreadTarget
  public let execution: ExecutionOptions
  public let supervisor: SupervisorOptions
  public let contract: TaskContract

  public init(
    schemaVersion: UInt16 = 1,
    idempotencyKey: IdempotencyKey,
    projectID: ProjectID,
    thread: ThreadTarget,
    execution: ExecutionOptions,
    supervisor: SupervisorOptions,
    contract: TaskContract
  ) {
    self.schemaVersion = schemaVersion
    self.idempotencyKey = idempotencyKey
    self.projectID = projectID
    self.thread = thread
    self.execution = execution
    self.supervisor = supervisor
    self.contract = contract
  }
}

public enum ThreadTarget: Codable, Equatable, Sendable {
  case new
  case existing(ThreadID)
}

public struct ExecutionOptions: Codable, Equatable, Sendable {
  public let model: String
  public let effort: String
  public let permissionMode: String
  public let networkAccess: Bool

  public init(
    model: String,
    effort: String,
    permissionMode: String,
    networkAccess: Bool
  ) {
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.networkAccess = networkAccess
  }
}

public struct SupervisorOptions: Codable, Equatable, Sendable {
  public let enabled: Bool
  public let model: String
  public let effort: String

  public init(enabled: Bool, model: String, effort: String) {
    self.enabled = enabled
    self.model = model
    self.effort = effort
  }
}

public struct TaskContract: Codable, Equatable, Sendable {
  public let goal: String
  public let background: String
  public let requirements: [String]
  public let acceptanceCriteria: [String]
  public let nonGoals: [String]
  public let constraints: [String]
  public let allowedPaths: [String]
  public let forbiddenPaths: [String]
  public let verification: [String]

  public init(
    goal: String,
    background: String = "",
    requirements: [String] = [],
    acceptanceCriteria: [String],
    nonGoals: [String] = [],
    constraints: [String] = [],
    allowedPaths: [String] = [],
    forbiddenPaths: [String] = [],
    verification: [String] = []
  ) {
    self.goal = goal
    self.background = background
    self.requirements = requirements
    self.acceptanceCriteria = acceptanceCriteria
    self.nonGoals = nonGoals
    self.constraints = constraints
    self.allowedPaths = allowedPaths
    self.forbiddenPaths = forbiddenPaths
    self.verification = verification
  }
}

public enum TaskPhase: String, Codable, Equatable, Hashable, Sendable {
  case draft
  case awaitingLocalApproval
  case preparing
  case running
  case awaitingCodexApproval
  case suspended
  case verifying
  case recovering
  case unknown
  case completed
  case failed
  case interrupted
  case rejected

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .interrupted, .rejected:
      true
    default:
      false
    }
  }
}

public enum TaskActivity: String, Codable, Equatable, Sendable {
  case idle
  case supervising
  case correcting
}

public struct ExecutionBinding: Codable, Equatable, Sendable {
  public let threadID: ThreadID
  public let turnID: TurnID
  public let turnGeneration: UInt64

  public init(threadID: ThreadID, turnID: TurnID, turnGeneration: UInt64) {
    self.threadID = threadID
    self.turnID = turnID
    self.turnGeneration = turnGeneration
  }
}

public struct StopIntent: Codable, Equatable, Sendable {
  public enum Outcome: String, Codable, Equatable, Sendable {
    case suspend
    case interrupt
  }

  public let operationID: OperationID
  public let outcome: Outcome
  public let reason: String?

  public init(operationID: OperationID, outcome: Outcome, reason: String? = nil) {
    self.operationID = operationID
    self.outcome = outcome
    self.reason = reason
  }
}

public struct TaskAggregate: Codable, Equatable, Sendable {
  public static let maximumApprovalEvidenceEncodedBytes = 256 * 1_024

  public let id: TaskID
  public let submission: TaskSubmission
  public internal(set) var phase: TaskPhase
  public internal(set) var activity: TaskActivity
  public internal(set) var binding: ExecutionBinding?
  public internal(set) var pendingApprovalIDs: Set<ApprovalID>
  public internal(set) var resolvingApprovalIDs: Set<ApprovalID>
  public internal(set) var approvalEvidenceByID: [ApprovalID: CodexApprovalEvidence]
  public internal(set) var stopIntent: StopIntent?
  public internal(set) var reportReference: String?
  public internal(set) var failureReason: String?
  public internal(set) var recoveryOrigin: TaskPhase?

  public init(id: TaskID, submission: TaskSubmission) {
    self.id = id
    self.submission = submission
    self.phase = .draft
    self.activity = .idle
    self.binding = nil
    self.pendingApprovalIDs = []
    self.resolvingApprovalIDs = []
    self.approvalEvidenceByID = [:]
    self.stopIntent = nil
    self.reportReference = nil
    self.failureReason = nil
    self.recoveryOrigin = nil
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case submission
    case phase
    case activity
    case binding
    case pendingApprovalIDs
    case resolvingApprovalIDs
    case approvalEvidenceByID
    case stopIntent
    case reportReference
    case failureReason
    case recoveryOrigin
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(TaskID.self, forKey: .id)
    submission = try container.decode(TaskSubmission.self, forKey: .submission)
    phase = try container.decode(TaskPhase.self, forKey: .phase)
    activity = try container.decode(TaskActivity.self, forKey: .activity)
    binding = try container.decodeIfPresent(ExecutionBinding.self, forKey: .binding)
    pendingApprovalIDs = try container.decode(Set<ApprovalID>.self, forKey: .pendingApprovalIDs)
    resolvingApprovalIDs =
      try container.decodeIfPresent(
        Set<ApprovalID>.self,
        forKey: .resolvingApprovalIDs
      ) ?? []
    approvalEvidenceByID =
      try container.decodeIfPresent(
        [ApprovalID: CodexApprovalEvidence].self,
        forKey: .approvalEvidenceByID
      ) ?? [:]
    guard Self.approvalEvidenceFitsBudget(approvalEvidenceByID) else {
      throw DecodingError.dataCorruptedError(
        forKey: .approvalEvidenceByID,
        in: container,
        debugDescription: "Approval evidence exceeds the aggregate byte limit."
      )
    }
    stopIntent = try container.decodeIfPresent(StopIntent.self, forKey: .stopIntent)
    reportReference = try container.decodeIfPresent(String.self, forKey: .reportReference)
    failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
    recoveryOrigin = try container.decodeIfPresent(TaskPhase.self, forKey: .recoveryOrigin)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(submission, forKey: .submission)
    try container.encode(phase, forKey: .phase)
    try container.encode(activity, forKey: .activity)
    try container.encodeIfPresent(binding, forKey: .binding)
    try container.encode(pendingApprovalIDs, forKey: .pendingApprovalIDs)
    try container.encode(resolvingApprovalIDs, forKey: .resolvingApprovalIDs)
    try container.encode(approvalEvidenceByID, forKey: .approvalEvidenceByID)
    try container.encodeIfPresent(stopIntent, forKey: .stopIntent)
    try container.encodeIfPresent(reportReference, forKey: .reportReference)
    try container.encodeIfPresent(failureReason, forKey: .failureReason)
    try container.encodeIfPresent(recoveryOrigin, forKey: .recoveryOrigin)
  }

  static func approvalEvidenceFitsBudget(
    _ evidenceByID: [ApprovalID: CodexApprovalEvidence]
  ) -> Bool {
    guard let data = try? JSONEncoder().encode(evidenceByID) else { return false }
    return data.count <= Self.maximumApprovalEvidenceEncodedBytes
  }
}
