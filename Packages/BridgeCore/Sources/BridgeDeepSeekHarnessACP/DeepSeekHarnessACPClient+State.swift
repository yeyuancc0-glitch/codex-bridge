import BridgeACP

extension DeepSeekHarnessACPClient {
  func requireInitialized() throws {
    if closed { throw DeepSeekHarnessACPError.transportClosed }
    guard initializationStorage != nil else {
      throw DeepSeekHarnessACPError.notInitialized
    }
  }

  func beginSessionOperation() throws {
    guard !sessionOperationInFlight else {
      throw DeepSeekHarnessACPError.operationInProgress
    }
    sessionOperationInFlight = true
  }

  func endSessionOperation() {
    sessionOperationInFlight = false
  }

  func requireSession(_ sessionID: String) throws {
    guard activeSessionID == sessionID else {
      throw DeepSeekHarnessACPError.sessionMismatch
    }
  }
}
