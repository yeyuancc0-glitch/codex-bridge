import Foundation

public struct IPCApprovalListRequest: Codable, Equatable, Sendable {
  public let taskID: String?

  public init(taskID: String? = nil) {
    self.taskID = taskID
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
  }
}

public struct IPCApprovalResolutionRequest: Codable, Equatable, Sendable {
  public let taskID: String
  public let approvalID: String
  public let decision: String

  public init(taskID: String, approvalID: String, decision: String) {
    self.taskID = taskID
    self.approvalID = approvalID
    self.decision = decision
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case approvalID = "approval_id"
    case decision
  }
}

public struct IPCPendingDirectApproval: Codable, Equatable, Sendable {
  public let approvalID: String
  public let projectID: String
  public let kind: String
  public let summary: String
  public let createdAt: Date

  public init(
    approvalID: String,
    projectID: String,
    kind: String,
    summary: String,
    createdAt: Date
  ) {
    self.approvalID = approvalID
    self.projectID = projectID
    self.kind = kind
    self.summary = summary
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case approvalID = "approval_id"
    case projectID = "project_id"
    case kind
    case summary
    case createdAt = "created_at"
  }
}

public struct IPCDirectApprovalDecisionRequest: Codable, Equatable, Sendable {
  public let approvalID: String

  public init(approvalID: String) {
    self.approvalID = approvalID
  }

  private enum CodingKeys: String, CodingKey {
    case approvalID = "approval_id"
  }
}

public struct IPCDirectApprovalListResponse: Codable, Equatable, Sendable {
  public let approvals: [IPCPendingDirectApproval]

  public init(approvals: [IPCPendingDirectApproval]) {
    self.approvals = approvals
  }
}

public struct IPCApprovalSummary: Codable, Equatable, Sendable {
  public let approvalID: String
  public let taskID: String
  public let threadID: String
  public let turnID: String
  public let itemID: String
  public let kind: String
  public let title: String
  public let summary: String
  public let displayCommand: String?
  public let relativePaths: [String]
  public let reason: String?

  public init(
    approvalID: String,
    taskID: String,
    threadID: String,
    turnID: String,
    itemID: String,
    kind: String,
    title: String,
    summary: String,
    displayCommand: String? = nil,
    relativePaths: [String] = [],
    reason: String? = nil
  ) {
    self.approvalID = approvalID
    self.taskID = taskID
    self.threadID = threadID
    self.turnID = turnID
    self.itemID = itemID
    self.kind = kind
    self.title = title
    self.summary = summary
    self.displayCommand = displayCommand
    self.relativePaths = relativePaths
    self.reason = reason
  }

  private enum CodingKeys: String, CodingKey {
    case approvalID = "approval_id"
    case taskID = "task_id"
    case threadID = "thread_id"
    case turnID = "turn_id"
    case itemID = "item_id"
    case kind
    case title
    case summary
    case displayCommand = "display_command"
    case relativePaths = "relative_paths"
    case reason
  }
}

public struct IPCApprovalListResponse: Codable, Equatable, Sendable {
  public let approvals: [IPCApprovalSummary]

  public init(approvals: [IPCApprovalSummary]) {
    self.approvals = approvals
  }
}
