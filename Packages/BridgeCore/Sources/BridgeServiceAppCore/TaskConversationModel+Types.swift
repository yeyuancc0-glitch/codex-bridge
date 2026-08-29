import BridgeIPC

extension TaskConversationModel {
  public enum Activity: Equatable {
    case idle
    case thinking
    case executing(String?)
    case responding
  }

  public struct Entry: Identifiable, Equatable {
    public let key: String
    public let role: String
    public let kind: String
    public let messageID: Int64?
    public var content: String
    public var toolName: String?
    public var toolStatus: String?
    public var toolArguments: String?
    public var isFinal: Bool

    public var id: String { key }

    public init(_ message: IPCTaskConversationMessage, isFinal: Bool) {
      key = message.key
      role = message.role
      kind = message.kind
      messageID = message.messageID
      content = message.content
      toolName = message.toolName
      toolStatus = message.toolStatus
      toolArguments = message.toolArguments
      self.isFinal = isFinal
    }

    public init(key: String, role: String, kind: String, content: String, isFinal: Bool) {
      self.key = key
      self.role = role
      self.kind = kind
      messageID = nil
      self.content = content
      toolName = nil
      toolStatus = nil
      toolArguments = nil
      self.isFinal = isFinal
    }
  }
}
