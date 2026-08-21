import Foundation

public enum CodexPlanStepStatus: String, Equatable, Sendable {
  case pending
  case inProgress
  case completed
}

public struct CodexPlanStepEvidence: Equatable, Sendable {
  public let text: String
  public let status: CodexPlanStepStatus
}

public struct CodexPlanUpdateEvidence: Equatable, Sendable {
  public let threadID: String
  public let turnID: String
  public let steps: [CodexPlanStepEvidence]
  public let explanation: String?
}

public struct CodexCompletedCommandEvidence: Equatable, Sendable {
  public let item: CodexApprovalItemKey
  public let completedAtMilliseconds: Int64
  public let displayCommand: String
  public let exitCode: Int32?
  public let status: CodexCommandExecutionStatus
}

public struct CodexCompletedFileChangeEvidence: Equatable, Sendable {
  public let item: CodexApprovalItemKey
  public let completedAtMilliseconds: Int64
  public let changes: [CodexFileUpdateEvidence]
  public let status: CodexFileChangeStatus
}

public enum CodexSemanticExecutionEvidence: Equatable, Sendable {
  case planChanged(CodexPlanUpdateEvidence)
  case commandCompleted(CodexCompletedCommandEvidence)
  case fileChangeCompleted(CodexCompletedFileChangeEvidence)
}
