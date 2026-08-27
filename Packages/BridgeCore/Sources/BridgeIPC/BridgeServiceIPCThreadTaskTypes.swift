import BridgeMCP
import Foundation

public struct IPCThreadListRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let cursor: String?
  public let limit: Int
  public let search: String?

  public init(projectID: String, cursor: String? = nil, limit: Int = 100, search: String? = nil) {
    self.projectID = projectID
    self.cursor = cursor
    self.limit = limit
    self.search = search
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case cursor
    case limit
    case search
  }
}

public struct IPCThreadReadRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let threadID: String
  public let detail: MCPThreadDetail
  public let cursor: String?
  public let limit: Int

  public init(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail = .summary,
    cursor: String? = nil,
    limit: Int = 100
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.detail = detail
    self.cursor = cursor
    self.limit = limit
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case threadID = "thread_id"
    case detail
    case cursor
    case limit
  }
}

public struct IPCTaskListRequest: Codable, Equatable, Sendable {
  public let projectID: String?
  public let limit: Int

  public init(projectID: String? = nil, limit: Int = 100) {
    self.projectID = projectID
    self.limit = limit
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case limit
  }
}

public struct IPCTaskRequest: Codable, Equatable, Sendable {
  public let taskID: String
  public let recentEventLimit: Int

  public init(taskID: String, recentEventLimit: Int = 50) {
    self.taskID = taskID
    self.recentEventLimit = recentEventLimit
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case recentEventLimit = "recent_event_limit"
  }
}

public struct IPCTaskSteerRequest: Codable, Equatable, Sendable {
  public static let maximumIdentifierBytes = 1_024
  public static let maximumInputBytes = 32 * 1_024

  public let taskID: String
  public let expectedTurnID: String
  public let input: String

  public init(taskID: String, expectedTurnID: String, input: String) {
    self.taskID = taskID
    self.expectedTurnID = expectedTurnID
    self.input = input
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case expectedTurnID = "expected_turn_id"
    case input
  }
}

public struct IPCTaskInterruptRequest: Codable, Equatable, Sendable {
  public static let maximumIdentifierBytes = 1_024

  public let taskID: String
  public let expectedTurnID: String

  public init(taskID: String, expectedTurnID: String) {
    self.taskID = taskID
    self.expectedTurnID = expectedTurnID
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case expectedTurnID = "expected_turn_id"
  }
}

public struct IPCTaskListResponse: Codable, Equatable, Sendable {
  public let tasks: [MCPServiceTaskSnapshot]

  public init(tasks: [MCPServiceTaskSnapshot]) {
    self.tasks = tasks
  }
}
