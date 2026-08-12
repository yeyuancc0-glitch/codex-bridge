import Foundation

public enum SupervisorCheckpointStage: String, Codable, Sendable {
  case progress
  case final
}

public enum SupervisorCheckpointTrigger: String, CaseIterable, Codable, Hashable, Sendable {
  case planChanged = "plan_changed"
  case firstFileModification = "first_file_modification"
  case changedFileThreshold = "changed_file_threshold"
  case diffThreshold = "diff_threshold"
  case commandFailed = "command_failed"
  case verificationFailed = "verification_failed"
  case scopeExpansionRequested = "scope_expansion_requested"
  case policyConcern = "policy_concern"
  case completionClaimed = "completion_claimed"
  case manual

  fileprivate var order: Int {
    switch self {
    case .planChanged: 0
    case .firstFileModification: 1
    case .changedFileThreshold: 2
    case .diffThreshold: 3
    case .commandFailed: 4
    case .verificationFailed: 5
    case .scopeExpansionRequested: 6
    case .policyConcern: 7
    case .completionClaimed: 8
    case .manual: 9
    }
  }
}

public struct SupervisorCommandResult: Codable, Equatable, Sendable {
  public let displayCommand: String
  public let exitCode: Int32

  public init(displayCommand: String, exitCode: Int32) {
    self.displayCommand = displayCommand
    self.exitCode = exitCode
  }
}

public enum SupervisorVerificationOutcome: String, Codable, Sendable {
  case passed
  case failed
  case skipped
}

public struct SupervisorVerificationResult: Codable, Equatable, Sendable {
  public let name: String
  public let outcome: SupervisorVerificationOutcome
  public let summary: String

  public init(name: String, outcome: SupervisorVerificationOutcome, summary: String) {
    self.name = name
    self.outcome = outcome
    self.summary = summary
  }
}

public struct SupervisorDecisionDigest: Codable, Equatable, Sendable {
  public let decision: SupervisorDecisionKind
  public let summary: String

  public init(decision: SupervisorDecisionKind, summary: String) {
    self.decision = decision
    self.summary = summary
  }
}

public struct SupervisorCheckpointContent: Codable, Equatable, Sendable {
  public let taskContract: String
  public let projectRulePaths: [String]
  public let executionModel: String
  public let executionEffort: String
  public let currentPlan: [String]
  public let recentEvents: [String]
  public let commandResults: [SupervisorCommandResult]
  public let changedFiles: [String]
  public let gitDiffSummary: String
  public let keyDiffs: [String]
  public let verificationResults: [SupervisorVerificationResult]
  public let previousDecisions: [SupervisorDecisionDigest]
  public let remainingAutomaticSteers: Int

  public init(
    taskContract: String,
    projectRulePaths: [String] = [],
    executionModel: String,
    executionEffort: String,
    currentPlan: [String] = [],
    recentEvents: [String] = [],
    commandResults: [SupervisorCommandResult] = [],
    changedFiles: [String] = [],
    gitDiffSummary: String = "No diff recorded.",
    keyDiffs: [String] = [],
    verificationResults: [SupervisorVerificationResult] = [],
    previousDecisions: [SupervisorDecisionDigest] = [],
    remainingAutomaticSteers: Int
  ) {
    self.taskContract = taskContract
    self.projectRulePaths = projectRulePaths
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.currentPlan = currentPlan
    self.recentEvents = recentEvents
    self.commandResults = commandResults
    self.changedFiles = changedFiles
    self.gitDiffSummary = gitDiffSummary
    self.keyDiffs = keyDiffs
    self.verificationResults = verificationResults
    self.previousDecisions = previousDecisions
    self.remainingAutomaticSteers = remainingAutomaticSteers
  }
}

public enum SupervisorCheckpointValidationError: Error, Equatable, Sendable {
  case invalidSequence
  case emptyTriggers
  case duplicateTriggers
  case emptyString(field: String)
  case stringTooLarge(field: String, maximumBytes: Int)
  case unsafeControlCharacter(field: String)
  case arrayTooLarge(field: String, maximumCount: Int)
  case invalidRemainingSteers
  case encodedPayloadTooLarge(maximumBytes: Int)
}

public struct SupervisorCheckpoint: Codable, Equatable, Sendable {
  public static let maximumEncodedBytes = 256 * 1024

  public let schemaVersion: UInt16
  public let sequence: UInt64
  public let taskID: String
  public let turnID: String
  public let stage: SupervisorCheckpointStage
  public let triggers: [SupervisorCheckpointTrigger]
  public let content: SupervisorCheckpointContent

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case sequence
    case taskID = "task_id"
    case turnID = "turn_id"
    case stage
    case triggers
    case content
  }

  public init(
    schemaVersion: UInt16 = 1,
    sequence: UInt64,
    taskID: String,
    turnID: String,
    stage: SupervisorCheckpointStage,
    triggers: [SupervisorCheckpointTrigger],
    content: SupervisorCheckpointContent
  ) throws {
    self.schemaVersion = schemaVersion
    self.sequence = sequence
    self.taskID = taskID
    self.turnID = turnID
    self.stage = stage
    self.triggers = triggers.sorted { $0.order < $1.order }
    self.content = content
    try validateFields()
    _ = try encodedData()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
      sequence: container.decode(UInt64.self, forKey: .sequence),
      taskID: container.decode(String.self, forKey: .taskID),
      turnID: container.decode(String.self, forKey: .turnID),
      stage: container.decode(SupervisorCheckpointStage.self, forKey: .stage),
      triggers: container.decode([SupervisorCheckpointTrigger].self, forKey: .triggers),
      content: container.decode(SupervisorCheckpointContent.self, forKey: .content)
    )
  }

  public func encodedData(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
    let data = try encoder.encode(self)
    guard data.count <= Self.maximumEncodedBytes else {
      throw SupervisorCheckpointValidationError.encodedPayloadTooLarge(
        maximumBytes: Self.maximumEncodedBytes
      )
    }
    return data
  }

  private func validateFields() throws {
    guard sequence > 0 else {
      throw SupervisorCheckpointValidationError.invalidSequence
    }
    guard !triggers.isEmpty else {
      throw SupervisorCheckpointValidationError.emptyTriggers
    }
    guard Set(triggers).count == triggers.count else {
      throw SupervisorCheckpointValidationError.duplicateTriggers
    }
    try Self.validate(taskID, field: "task_id", maximumBytes: 256)
    try Self.validate(turnID, field: "turn_id", maximumBytes: 256)
    try Self.validate(content.taskContract, field: "task_contract", maximumBytes: 32 * 1024)
    try Self.validate(content.executionModel, field: "execution_model", maximumBytes: 256)
    try Self.validate(content.executionEffort, field: "execution_effort", maximumBytes: 64)
    try Self.validate(content.gitDiffSummary, field: "git_diff_summary", maximumBytes: 16 * 1024)
    try validateCollections()
    guard (0...5).contains(content.remainingAutomaticSteers) else {
      throw SupervisorCheckpointValidationError.invalidRemainingSteers
    }
  }

  private func validateCollections() throws {
    try Self.validate(content.projectRulePaths, field: "project_rule_paths")
    try Self.validate(content.currentPlan, field: "current_plan")
    try Self.validate(content.recentEvents, field: "recent_events")
    try Self.validate(content.changedFiles, field: "changed_files")
    try Self.validate(content.keyDiffs, field: "key_diffs", maximumCount: 32, maximumBytes: 8192)
    guard content.commandResults.count <= 128 else {
      throw SupervisorCheckpointValidationError.arrayTooLarge(
        field: "command_results",
        maximumCount: 128
      )
    }
    for result in content.commandResults {
      try Self.validate(result.displayCommand, field: "display_command", maximumBytes: 4096)
    }
    guard content.verificationResults.count <= 128 else {
      throw SupervisorCheckpointValidationError.arrayTooLarge(
        field: "verification_results",
        maximumCount: 128
      )
    }
    for result in content.verificationResults {
      try Self.validate(result.name, field: "verification_name", maximumBytes: 512)
      try Self.validate(result.summary, field: "verification_summary", maximumBytes: 4096)
    }
    guard content.previousDecisions.count <= 16 else {
      throw SupervisorCheckpointValidationError.arrayTooLarge(
        field: "previous_decisions",
        maximumCount: 16
      )
    }
    for digest in content.previousDecisions {
      try Self.validate(digest.summary, field: "previous_decision", maximumBytes: 2048)
    }
  }

  private static func validate(
    _ values: [String],
    field: String,
    maximumCount: Int = 128,
    maximumBytes: Int = 4096
  ) throws {
    guard values.count <= maximumCount else {
      throw SupervisorCheckpointValidationError.arrayTooLarge(
        field: field,
        maximumCount: maximumCount
      )
    }
    for value in values {
      try validate(value, field: field, maximumBytes: maximumBytes)
    }
  }

  private static func validate(_ value: String, field: String, maximumBytes: Int) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SupervisorCheckpointValidationError.emptyString(field: field)
    }
    guard value.utf8.count <= maximumBytes else {
      throw SupervisorCheckpointValidationError.stringTooLarge(
        field: field,
        maximumBytes: maximumBytes
      )
    }
    let unsafe = value.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x09, 0x0A, 0x0D:
        false
      case 0..<0x20, 0x7F:
        true
      default:
        false
      }
    }
    guard !unsafe else {
      throw SupervisorCheckpointValidationError.unsafeControlCharacter(field: field)
    }
  }
}
