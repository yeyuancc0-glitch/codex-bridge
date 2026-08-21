import Foundation

public enum ReportingError: Error, Equatable, Sendable {
  case invalidEvidence(String)
  case missingEvidence(String)
  case limitExceeded(field: String, maximum: Int)
}

public struct ReportingLimits: Codable, Equatable, Sendable {
  public static let standard = ReportingLimits()

  public let maximumJSONBytes: Int
  public let maximumStringBytes: Int
  public let maximumPathBytes: Int
  public let maximumItems: Int
  public let maximumArgumentsPerCommand: Int
  public let maximumSensitiveValues: Int

  public init(
    maximumJSONBytes: Int = 192 * 1_024,
    maximumStringBytes: Int = 16 * 1_024,
    maximumPathBytes: Int = 4 * 1_024,
    maximumItems: Int = 256,
    maximumArgumentsPerCommand: Int = 64,
    maximumSensitiveValues: Int = 64
  ) {
    self.maximumJSONBytes = maximumJSONBytes
    self.maximumStringBytes = maximumStringBytes
    self.maximumPathBytes = maximumPathBytes
    self.maximumItems = maximumItems
    self.maximumArgumentsPerCommand = maximumArgumentsPerCommand
    self.maximumSensitiveValues = maximumSensitiveValues
  }
}

public struct ReportingRedactionPolicy: Equatable, Sendable {
  public let sensitiveValues: [String]

  public init(sensitiveValues: [String] = []) {
    self.sensitiveValues = sensitiveValues
  }
}

public enum FinalReportStatus: String, Codable, Equatable, Sendable {
  case completed
  case failed
  case interrupted
  case rejected
}

public enum AppServerTerminalState: String, Codable, Equatable, Sendable {
  case completed
  case failed
  case interrupted
}

public struct AppServerCommandEvidence: Codable, Equatable, Sendable {
  public let sequence: Int64
  public let executable: String
  public let arguments: [String]
  public let exitCode: Int32?

  public init(
    sequence: Int64,
    executable: String,
    arguments: [String] = [],
    exitCode: Int32? = nil
  ) {
    self.sequence = sequence
    self.executable = executable
    self.arguments = arguments
    self.exitCode = exitCode
  }
}

public struct AppServerEvidence: Codable, Equatable, Sendable {
  public let threadID: String
  public let model: String
  public let effort: String
  public let terminalState: AppServerTerminalState
  public let commands: [AppServerCommandEvidence]
  public let startedAt: Date
  public let completedAt: Date

  public init(
    threadID: String,
    model: String,
    effort: String,
    terminalState: AppServerTerminalState,
    commands: [AppServerCommandEvidence] = [],
    startedAt: Date,
    completedAt: Date
  ) {
    self.threadID = threadID
    self.model = model
    self.effort = effort
    self.terminalState = terminalState
    self.commands = commands
    self.startedAt = startedAt
    self.completedAt = completedAt
  }
}

public enum GitChangeKind: String, Codable, Equatable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case untracked
}

public struct GitChangedFileEvidence: Codable, Equatable, Sendable {
  public let relativePath: String
  public let change: GitChangeKind

  public init(relativePath: String, change: GitChangeKind) {
    self.relativePath = relativePath
    self.change = change
  }
}

public struct GitEvidence: Codable, Equatable, Sendable {
  public let baselineCaptured: Bool
  public let finalStateCaptured: Bool
  public let dirtyAtStart: Bool
  public let changedFiles: [GitChangedFileEvidence]
  public let diffStat: String
  public let commit: String?

  public init(
    baselineCaptured: Bool,
    finalStateCaptured: Bool,
    dirtyAtStart: Bool,
    changedFiles: [GitChangedFileEvidence],
    diffStat: String,
    commit: String? = nil
  ) {
    self.baselineCaptured = baselineCaptured
    self.finalStateCaptured = finalStateCaptured
    self.dirtyAtStart = dirtyAtStart
    self.changedFiles = changedFiles
    self.diffStat = diffStat
    self.commit = commit
  }
}

public enum VerificationStatus: String, Codable, Equatable, Sendable {
  case passed
  case failed
  case unavailable
}

public struct VerificationEvidence: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let required: Bool
  public let status: VerificationStatus
  public let exitCode: Int32?
  public let unavailableReason: String?

  public init(
    id: String,
    name: String,
    required: Bool,
    status: VerificationStatus,
    exitCode: Int32? = nil,
    unavailableReason: String? = nil
  ) {
    self.id = id
    self.name = name
    self.required = required
    self.status = status
    self.exitCode = exitCode
    self.unavailableReason = unavailableReason
  }
}

public enum SupervisorFinalDecision: String, Codable, Equatable, Sendable {
  case `continue`
  case steer
  case suspend
  case interrupt
  case finalAccept = "final_accept"
  case finalReject = "final_reject"
}

public struct SupervisorEvidence: Codable, Equatable, Sendable {
  public let model: String
  public let effort: String
  public let checks: Int
  public let steers: Int
  public let finalDecision: SupervisorFinalDecision

  public init(
    model: String,
    effort: String,
    checks: Int,
    steers: Int,
    finalDecision: SupervisorFinalDecision
  ) {
    self.model = model
    self.effort = effort
    self.checks = checks
    self.steers = steers
    self.finalDecision = finalDecision
  }
}

public struct PolicyEvidence: Codable, Equatable, Sendable {
  public let evaluationCompleted: Bool
  public let unresolvedBlockers: [String]
  public let warnings: [String]

  public init(
    evaluationCompleted: Bool,
    unresolvedBlockers: [String] = [],
    warnings: [String] = []
  ) {
    self.evaluationCompleted = evaluationCompleted
    self.unresolvedBlockers = unresolvedBlockers
    self.warnings = warnings
  }
}

public struct UserCompletionOverride: Codable, Equatable, Sendable {
  public let decisionID: String
  public let reason: String
  public let confirmedAt: Date

  public init(decisionID: String, reason: String, confirmedAt: Date) {
    self.decisionID = decisionID
    self.reason = reason
    self.confirmedAt = confirmedAt
  }
}

public struct FinalReportInput: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: FinalReportStatus
  public let project: String
  public let appServer: AppServerEvidence
  public let git: GitEvidence
  public let verification: [VerificationEvidence]
  public let supervisor: SupervisorEvidence?
  public let policy: PolicyEvidence
  public let userOverride: UserCompletionOverride?
  public let untrustedCodexNarrative: String?

  public init(
    taskID: String,
    status: FinalReportStatus,
    project: String,
    appServer: AppServerEvidence,
    git: GitEvidence,
    verification: [VerificationEvidence],
    supervisor: SupervisorEvidence?,
    policy: PolicyEvidence,
    userOverride: UserCompletionOverride? = nil,
    untrustedCodexNarrative: String? = nil
  ) {
    self.taskID = taskID
    self.status = status
    self.project = project
    self.appServer = appServer
    self.git = git
    self.verification = verification
    self.supervisor = supervisor
    self.policy = policy
    self.userOverride = userOverride
    self.untrustedCodexNarrative = untrustedCodexNarrative
  }
}

public enum ReportFactSource: String, Codable, Equatable, Sendable {
  case appServerEvents = "app_server_events"
  case gitEvidence = "git_evidence"
  case verificationExits = "verification_exits"
  case supervisorDecision = "supervisor_decision"
  case policyEngine = "policy_engine"
}

public struct ExecutionReport: Codable, Equatable, Sendable {
  public let model: String
  public let effort: String
}

public struct AppServerReportEvidence: Codable, Equatable, Sendable {
  public let threadID: String
  public let model: String
  public let effort: String
  public let terminalState: AppServerTerminalState
  public let commands: [AppServerCommandEvidence]
  public let startedAt: Date
  public let completedAt: Date
}

public enum CompletionAuthority: String, Codable, Equatable, Sendable {
  case supervisorFinalAccept = "supervisor_final_accept"
  case userOverride = "user_override"
}

public struct ReportEvidence: Codable, Equatable, Sendable {
  public let sources: [ReportFactSource]
  public let appServer: AppServerReportEvidence
  public let git: GitEvidence
  public let verification: [VerificationEvidence]
  public let supervisor: SupervisorEvidence?
  public let policy: PolicyEvidence
  public let completionAuthority: CompletionAuthority?
  public let userOverride: UserCompletionOverride?
}

public struct FinalReport: Codable, Equatable, Sendable {
  public let schemaVersion: UInt16
  public let taskID: String
  public let status: FinalReportStatus
  public let project: String
  public let threadID: String
  public let execution: ExecutionReport
  public let supervisor: SupervisorEvidence?
  public let summary: String
  public let changedFiles: [GitChangedFileEvidence]
  public let diffStat: String
  public let commands: [AppServerCommandEvidence]
  public let verification: [VerificationEvidence]
  public let warnings: [String]
  public let unresolvedItems: [String]
  public let commit: String?
  public let startedAt: Date
  public let completedAt: Date
  public let evidence: ReportEvidence
}

public struct FinalReportDocument: Equatable, Sendable {
  public let report: FinalReport
  public let json: Data
}

public enum SupportRecordSource: String, Codable, Equatable, Sendable {
  case applicationDiagnostic = "application_diagnostic"
  case connectionStatus = "connection_status"
  case policyDecision = "policy_decision"
  case verificationResult = "verification_result"
  case reportSummary = "report_summary"
}

public enum SupportRecordLevel: String, Codable, Equatable, Sendable {
  case debug
  case info
  case warning
  case error
}

public struct SupportRecordField: Codable, Equatable, Sendable {
  public let key: String
  public let value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

public struct AllowedSupportRecord: Codable, Equatable, Sendable {
  public let id: String
  public let source: SupportRecordSource
  public let level: SupportRecordLevel
  public let timestamp: Date
  public let summary: String
  public let fields: [SupportRecordField]

  public init(
    id: String,
    source: SupportRecordSource,
    level: SupportRecordLevel,
    timestamp: Date,
    summary: String,
    fields: [SupportRecordField] = []
  ) {
    self.id = id
    self.source = source
    self.level = level
    self.timestamp = timestamp
    self.summary = summary
    self.fields = fields
  }
}

public struct SupportBundleLimits: Codable, Equatable, Sendable {
  public static let standard = SupportBundleLimits()

  public let maximumJSONBytes: Int
  public let maximumStringBytes: Int
  public let maximumRecords: Int
  public let maximumFieldsPerRecord: Int
  public let maximumSensitiveValues: Int

  public init(
    maximumJSONBytes: Int = 1_024 * 1_024,
    maximumStringBytes: Int = 16 * 1_024,
    maximumRecords: Int = 512,
    maximumFieldsPerRecord: Int = 64,
    maximumSensitiveValues: Int = 64
  ) {
    self.maximumJSONBytes = maximumJSONBytes
    self.maximumStringBytes = maximumStringBytes
    self.maximumRecords = maximumRecords
    self.maximumFieldsPerRecord = maximumFieldsPerRecord
    self.maximumSensitiveValues = maximumSensitiveValues
  }
}

public struct SupportBundleInput: Codable, Equatable, Sendable {
  public let generatedAt: Date
  public let records: [AllowedSupportRecord]

  public init(generatedAt: Date, records: [AllowedSupportRecord]) {
    self.generatedAt = generatedAt
    self.records = records
  }
}

public struct SupportBundle: Codable, Equatable, Sendable {
  public let schemaVersion: UInt16
  public let generatedAt: Date
  public let records: [AllowedSupportRecord]
  public let redactionCount: Int
}

public struct SupportBundleDocument: Equatable, Sendable {
  public let bundle: SupportBundle
  public let json: Data
}
