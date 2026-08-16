import BridgeDomain
import BridgeGit
import Foundation

public enum PipelineArtifactStoreError: Error, Equatable, Sendable {
  case invalidArgument(String)
  case limitExceeded(field: String, maximum: Int)
  case databaseUnavailable
  case corruptSchema
  case unsupportedSchemaVersion(Int64)
  case unknownMigration(String)
  case corruptRecord
  case scopeConflict(TaskID)
  case artifactConflict(TaskID, PipelineArtifactKind)
  case patchReferenceConflict(TaskID)
  case patchReleasePending(String)
  case retentionInProgress(TaskID)
  case retentionRequiresTerminalScopes(TaskID)
  case retentionManifestConflict(TaskID)
  case invalidStageTransition(from: PipelineStage, to: PipelineStage)
  case missingPrerequisite(PipelineArtifactKind)
}

public struct TaskEvidenceScope: Codable, Equatable, Hashable, Sendable {
  public let taskID: TaskID
  public let projectID: ProjectID
  public let threadID: ThreadID
  public let turnID: TurnID
  public let generation: Int64
  public let eventSequence: Int64

  public init(
    taskID: TaskID,
    projectID: ProjectID,
    threadID: ThreadID,
    turnID: TurnID,
    generation: Int64,
    eventSequence: Int64
  ) throws {
    try Self.validate(taskID.rawValue, field: "taskID", maximum: 256)
    try Self.validate(projectID.rawValue, field: "projectID", maximum: 256)
    try Self.validate(threadID.rawValue, field: "threadID", maximum: 1_024)
    try Self.validate(turnID.rawValue, field: "turnID", maximum: 1_024)
    guard generation > 0 else {
      throw PipelineArtifactStoreError.invalidArgument("generation")
    }
    guard eventSequence > 0 else {
      throw PipelineArtifactStoreError.invalidArgument("eventSequence")
    }
    self.taskID = taskID
    self.projectID = projectID
    self.threadID = threadID
    self.turnID = turnID
    self.generation = generation
    self.eventSequence = eventSequence
  }

  private enum CodingKeys: String, CodingKey {
    case taskID
    case projectID
    case threadID
    case turnID
    case generation
    case eventSequence
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      taskID: container.decode(TaskID.self, forKey: .taskID),
      projectID: container.decode(ProjectID.self, forKey: .projectID),
      threadID: container.decode(ThreadID.self, forKey: .threadID),
      turnID: container.decode(TurnID.self, forKey: .turnID),
      generation: container.decode(Int64.self, forKey: .generation),
      eventSequence: container.decode(Int64.self, forKey: .eventSequence)
    )
  }

  private static func validate(_ value: String, field: String, maximum: Int) throws {
    guard !value.isEmpty, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw PipelineArtifactStoreError.invalidArgument(field)
    }
    guard value.utf8.count <= maximum else {
      throw PipelineArtifactStoreError.limitExceeded(field: field, maximum: maximum)
    }
  }
}

public enum PipelineArtifactKind: Codable, Equatable, Hashable, Sendable {
  case gitBaseline
  case gitFinal
  case verification(String)
  case supervisorFinalDecision
  case reportMetadata

  var category: String {
    switch self {
    case .gitBaseline: "git_baseline"
    case .gitFinal: "git_final"
    case .verification: "verification"
    case .supervisorFinalDecision: "supervisor_final"
    case .reportMetadata: "report_metadata"
    }
  }

  var key: String {
    switch self {
    case .verification(let identifier): identifier
    default: ""
    }
  }

  static func decode(category: String, key: String) throws -> Self {
    switch (category, key) {
    case ("git_baseline", ""): return .gitBaseline
    case ("git_final", ""): return .gitFinal
    case ("supervisor_final", ""): return .supervisorFinalDecision
    case ("report_metadata", ""): return .reportMetadata
    case ("verification", _):
      try validateVerificationIdentifier(key)
      return .verification(key)
    default: throw PipelineArtifactStoreError.corruptRecord
    }
  }

  func validated() throws -> Self {
    if case .verification(let identifier) = self {
      try Self.validateVerificationIdentifier(identifier)
    }
    return self
  }

  private static func validateVerificationIdentifier(_ value: String) throws {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !value.isEmpty, value.utf8.count <= 256,
      value.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw PipelineArtifactStoreError.invalidArgument("verificationIdentifier")
    }
  }
}

public enum PipelineStage: String, Codable, CaseIterable, Sendable {
  case created
  case baselineCaptured = "baseline_captured"
  case turnCompleted = "turn_completed"
  case gitFinalCaptured = "git_final_captured"
  case verificationCompleted = "verification_completed"
  case supervisorReviewed = "supervisor_reviewed"
  case reportStored = "report_stored"
  case completed
  case failed
  case superseded

  var isTerminal: Bool {
    self == .completed || self == .failed || self == .superseded
  }

  var isPendingFinalization: Bool {
    switch self {
    case .turnCompleted, .gitFinalCaptured, .verificationCompleted, .supervisorReviewed,
      .reportStored:
      true
    default: false
    }
  }

  var next: PipelineStage? {
    switch self {
    case .created: .baselineCaptured
    case .baselineCaptured: .turnCompleted
    case .turnCompleted: .gitFinalCaptured
    case .gitFinalCaptured: .verificationCompleted
    case .verificationCompleted: .supervisorReviewed
    case .supervisorReviewed: .reportStored
    case .reportStored: .completed
    case .completed, .failed, .superseded: nil
    }
  }
}

public struct PipelineArtifactRecord: Codable, Equatable, Sendable {
  public let scope: TaskEvidenceScope
  public let kind: PipelineArtifactKind
  public let schemaVersion: UInt16
  public let payloadByteCount: Int
  public let sha256: String
  public let createdAt: Date

  public init(
    scope: TaskEvidenceScope,
    kind: PipelineArtifactKind,
    schemaVersion: UInt16,
    payloadByteCount: Int,
    sha256: String,
    createdAt: Date
  ) {
    self.scope = scope
    self.kind = kind
    self.schemaVersion = schemaVersion
    self.payloadByteCount = payloadByteCount
    self.sha256 = sha256
    self.createdAt = createdAt
  }
}

public struct PipelineCompletionEvidenceRecord: Sendable {
  public let supervisor: PipelineSupervisorFinalEvidence?
  public let deterministicPolicy: PipelineDeterministicPolicyFinalEvidence?

  public init(
    supervisor: PipelineSupervisorFinalEvidence?,
    deterministicPolicy: PipelineDeterministicPolicyFinalEvidence?
  ) {
    self.supervisor = supervisor
    self.deterministicPolicy = deterministicPolicy
  }
}

public struct PipelineFinalizationRecord: Codable, Equatable, Sendable {
  public let scope: TaskEvidenceScope
  public let stage: PipelineStage
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    scope: TaskEvidenceScope,
    stage: PipelineStage,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.scope = scope
    self.stage = stage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct PipelinePatchReleaseManifest: Codable, Equatable, Sendable {
  public let taskID: TaskID
  public let patches: [GitPatchHandle]
  public let createdAt: Date
  public let sha256: String
}
