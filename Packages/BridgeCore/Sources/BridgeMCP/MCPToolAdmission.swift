public actor MCPToolAdmission {
  public let globalLimit: Int
  public let perSessionLimit: Int

  private var activeCount = 0
  private var activeBySession: [String: Int] = [:]

  public init(globalLimit: Int = 8, perSessionLimit: Int = 2) {
    precondition(globalLimit > 0)
    precondition(perSessionLimit > 0 && perSessionLimit <= globalLimit)
    self.globalLimit = globalLimit
    self.perSessionLimit = perSessionLimit
  }

  func acquire(sessionID: String) -> Bool {
    let sessionCount = activeBySession[sessionID, default: 0]
    guard activeCount < globalLimit, sessionCount < perSessionLimit else { return false }
    activeCount += 1
    activeBySession[sessionID] = sessionCount + 1
    return true
  }

  func release(sessionID: String) {
    guard let sessionCount = activeBySession[sessionID], sessionCount > 0 else { return }
    activeCount -= 1
    if sessionCount == 1 {
      activeBySession.removeValue(forKey: sessionID)
    } else {
      activeBySession[sessionID] = sessionCount - 1
    }
  }
}
