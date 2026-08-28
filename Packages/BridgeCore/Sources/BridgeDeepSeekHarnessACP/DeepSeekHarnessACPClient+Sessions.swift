import BridgeACP
import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPClient {
  public func newSession(cwd: String) async throws -> DeepSeekHarnessACPSession {
    try requireInitialized()
    try validateAbsolutePath(cwd, field: "session.cwd")
    guard activeSessionID == nil else { throw DeepSeekHarnessACPError.sessionMismatch }
    try beginSessionOperation()
    defer { endSessionOperation() }
    let response = try await request(
      method: "session/new",
      params: .object([
        "cwd": .string(cwd),
        "mcpServers": .array([]),
        "additionalDirectories": .array([]),
      ])
    )
    guard let sessionID = response.value["sessionId"]?.stringValue else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
    try validateIdentifier(sessionID, field: "session.id")
    let configOptions = try Self.parseConfigOptions(response.value["configOptions"])
    activeSessionID = sessionID
    return DeepSeekHarnessACPSession(id: sessionID, configOptions: configOptions)
  }

  public func setSessionConfigOption(
    sessionID: String,
    configID: String,
    value: String
  ) async throws -> [DeepSeekHarnessACPConfigOption] {
    try requireInitialized()
    try validateIdentifier(sessionID, field: "session.id")
    try validateIdentifier(configID, field: "session.configID")
    try validateIdentifier(value, field: "session.configValue")
    try requireSession(sessionID)
    try beginSessionOperation()
    defer { endSessionOperation() }
    let response = try await request(
      method: "session/set_config_option",
      params: .object([
        "sessionId": .string(sessionID),
        "configId": .string(configID),
        "value": .string(value),
      ])
    )
    return try Self.parseConfigOptions(response.value["configOptions"])
  }

  public func prompt(sessionID: String, text: String) async throws -> DeepSeekHarnessACPPromptResult
  {
    try requireInitialized()
    try validateIdentifier(sessionID, field: "session.id")
    try requireSession(sessionID)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 32 * 1_024,
      !text.contains("\0")
    else {
      throw AgentRuntimeError.invalidRequest("prompt.text")
    }
    try beginSessionOperation()
    defer { endSessionOperation() }
    let response = try await request(
      method: "session/prompt",
      params: .object([
        "sessionId": .string(sessionID),
        "prompt": .array([
          .object([
            "type": .string("text"),
            "text": .string(text),
          ])
        ]),
      ]),
      timeout: DeepSeekHarnessACPConstants.maximumProcessLifetime
    )
    guard let stopReason = response.value["stopReason"]?.stringValue,
      !stopReason.isEmpty,
      stopReason.utf8.count <= 128,
      !stopReason.contains("\0"),
      stopReason.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
    return DeepSeekHarnessACPPromptResult(
      stopReason: stopReason,
      eventSequenceBarrier: response.eventSequenceBarrier
    )
  }

  public func cancel(sessionID: String) async throws {
    try requireInitialized()
    try validateIdentifier(sessionID, field: "session.id")
    try requireSession(sessionID)
    try await broker.send(
      ACPWireMessage(
        method: "session/cancel",
        params: .object(["sessionId": .string(sessionID)])
      )
    )
  }

  public func shutdown() async {
    guard !closed else { return }
    closed = true
    let pending = Array(pendingPermissions.values)
    pendingPermissions.removeAll()
    for request in pending {
      try? await broker.send(
        ACPWireMessage(
          id: request.requestID,
          result: Self.permissionSelection(optionID: Self.rejectOptionID(in: request.options))
        )
      )
    }
    if let activeSessionID, initializationStorage != nil {
      try? await broker.send(
        ACPWireMessage(
          method: "session/cancel",
          params: .object(["sessionId": .string(activeSessionID)])
        )
      )
    }
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    readerTask?.cancel()
    readerTask = nil
    eventContinuation.finish()
    await broker.close()
  }
}
