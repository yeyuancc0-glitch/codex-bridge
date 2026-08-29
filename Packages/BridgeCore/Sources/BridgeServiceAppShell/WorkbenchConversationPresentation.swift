import BridgeMCP

enum WorkbenchConversationSource: Equatable {
  case task
  case historicalThread
  case empty

  static func resolve(
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
  init(historicalThreadEntry entry: MCPThreadEntry, threadID: String, index: Int) {
    self.init(
      key: "history:\(threadID):\(index)",
      role: entry.role == "user" ? "user" : "agent",
      kind: "agent",
      content: entry.text,
      isFinal: true
    )
  }
}
