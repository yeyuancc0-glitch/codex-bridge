import BridgeACP
import BridgeAgentCore

extension OpenCodeACPClient {
  func requireInitialized() throws {
    guard initializationStorage != nil, !closed else {
      throw OpenCodeACPError.notInitialized
    }
  }

  func beginSessionOperation() throws {
    guard !sessionOperationInFlight else {
      throw OpenCodeACPError.operationInProgress
    }
    sessionOperationInFlight = true
  }

  func endSessionOperation() {
    sessionOperationInFlight = false
  }

  func ensureCanBindSession(_ sessionID: String) throws {
    guard activeSessionID == nil || activeSessionID == sessionID else {
      throw OpenCodeACPError.sessionMismatch
    }
  }

  func bindSession(_ sessionID: String) throws {
    try ensureCanBindSession(sessionID)
    activeSessionID = sessionID
  }

  func requireSession(_ sessionID: String) throws {
    guard activeSessionID == sessionID else {
      throw OpenCodeACPError.sessionMismatch
    }
  }
}
