import BridgeMCP

public enum WorkbenchConversationSource: Equatable {
  case task
  case historicalThread
  case empty

  public static func resolve(
    hasSelectedTask: Bool,
    historicalEntryCount: Int
  ) -> Self {
    if hasSelectedTask {
      return .task
    }
    return historicalEntryCount > 0 ? .historicalThread : .empty
  }
}

extension TaskConversationModel.Entry {
  public init(historicalThreadEntry entry: MCPThreadEntry, threadID: String, index: Int) {
    self.init(
      key: "history:\(threadID):\(index)",
      role: entry.role == "user" ? "user" : "agent",
      kind: "agent",
      content: entry.text,
      isFinal: true
    )
  }
}
