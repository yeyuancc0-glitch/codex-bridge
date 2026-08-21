import Foundation

public struct IPCTaskConversationRequest: Codable, Equatable, Sendable {
  public let taskID: String
  public let beforeMessageID: Int64?
  public let limit: Int

  public init(taskID: String, beforeMessageID: Int64? = nil, limit: Int = 200) {
    self.taskID = taskID
    self.beforeMessageID = beforeMessageID
    self.limit = limit
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case beforeMessageID = "before_message_id"
    case limit
  }
}

public struct IPCTaskConversationMessage: Codable, Equatable, Sendable {
  public let messageID: Int64?
  public let key: String
  public let role: String
  public let kind: String
  public let content: String
  public let toolName: String?
  public let toolStatus: String?
  public let toolArguments: String?
  public let final: Bool

  public init(
    messageID: Int64?,
    key: String,
    role: String,
    kind: String = "agent",
    content: String,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil,
    final: Bool = true
  ) {
    self.messageID = messageID
    self.key = key
    self.role = role
    self.kind = kind
    self.content = content
    self.toolName = toolName
    self.toolStatus = toolStatus
    self.toolArguments = toolArguments
    self.final = final
  }

  private enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case key
    case role
    case kind
    case content
    case toolName = "tool_name"
    case toolStatus = "tool_status"
    case toolArguments = "tool_arguments"
    case final
  }
}

public struct IPCTaskConversationPage: Codable, Equatable, Sendable {
  public let taskID: String
  public let messages: [IPCTaskConversationMessage]

  public init(taskID: String, messages: [IPCTaskConversationMessage]) {
    self.taskID = taskID
    self.messages = messages
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case messages
  }
}

public struct IPCTaskConversationPush: Codable, Equatable, Sendable {
  public let taskID: String
  public let key: String
  public let role: String
  public let kind: String
  public let delta: String?
  public let baseContentLength: Int
  public let fullContent: String?
  public let final: Bool
  public let toolName: String?
  public let toolStatus: String?
  public let toolArguments: String?

  public init(
    taskID: String,
    key: String,
    role: String,
    kind: String = "agent",
    delta: String?,
    baseContentLength: Int,
    fullContent: String?,
    final: Bool,
    toolName: String? = nil,
    toolStatus: String? = nil,
    toolArguments: String? = nil
  ) {
    self.taskID = taskID
    self.key = key
    self.role = role
    self.kind = kind
    self.delta = delta
    self.baseContentLength = baseContentLength
    self.fullContent = fullContent
    self.final = final
    self.toolName = toolName
    self.toolStatus = toolStatus
    self.toolArguments = toolArguments
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case key
    case role
    case kind
    case delta
    case baseContentLength = "base_content_length"
    case fullContent = "full_content"
    case final
    case toolName = "tool_name"
    case toolStatus = "tool_status"
    case toolArguments = "tool_arguments"
  }
}

public struct IPCTaskConversationSubscription: Codable, Equatable, Sendable {
  public let subscriptionID: Int
  public let page: IPCTaskConversationPage

  public init(subscriptionID: Int, page: IPCTaskConversationPage) {
    self.subscriptionID = subscriptionID
    self.page = page
  }

  private enum CodingKeys: String, CodingKey {
    case subscriptionID = "subscription_id"
    case page
  }
}

public struct IPCTaskConversationUnsubscribeRequest: Codable, Equatable, Sendable {
  public let taskID: String
  public let subscriptionID: Int

  public init(taskID: String, subscriptionID: Int) {
    self.taskID = taskID
    self.subscriptionID = subscriptionID
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case subscriptionID = "subscription_id"
  }
}
