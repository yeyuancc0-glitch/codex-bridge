import BridgeACP
import BridgeAgentCore
import Foundation

extension OpenCodeACPClient {
  public func newSession(cwd: String) async throws -> OpenCodeACPSession {
    try requireInitialized()
    try validateAbsolutePath(cwd)
    guard activeSessionID == nil else { throw OpenCodeACPError.sessionMismatch }
    try beginSessionOperation()
    defer { endSessionOperation() }

    let response = try await request(
      method: "session/new",
      params: .object([
        "cwd": .string(cwd),
        "mcpServers": .array([]),
      ])
    )
    let session = try Self.parseSession(response.value)
    try bindSession(session.id)
    return session
  }

  public func loadSession(id: String, cwd: String) async throws -> OpenCodeACPSession {
    try requireInitialized()
    try validateIdentifier(id)
    try validateAbsolutePath(cwd)
    try ensureCanBindSession(id)
    try beginSessionOperation()
    defer { endSessionOperation() }

    let response = try await request(
      method: "session/load",
      params: .object([
        "sessionId": .string(id),
        "cwd": .string(cwd),
        "mcpServers": .array([]),
      ])
    )
    let session = try Self.parseSession(response.value, fallbackID: id)
    guard session.id == id else { throw OpenCodeACPError.sessionMismatch }
    try bindSession(session.id)
    return session
  }

  public func resumeSession(id: String, cwd: String) async throws -> OpenCodeACPSession {
    try requireInitialized()
    try validateIdentifier(id)
    try validateAbsolutePath(cwd)
    try ensureCanBindSession(id)
    try beginSessionOperation()
    defer { endSessionOperation() }

    let response = try await request(
      method: "session/resume",
      params: .object([
        "sessionId": .string(id),
        "cwd": .string(cwd),
        "mcpServers": .array([]),
      ])
    )
    let session = try Self.parseSession(response.value, fallbackID: id)
    guard session.id == id else { throw OpenCodeACPError.sessionMismatch }
    try bindSession(session.id)
    return session
  }

  public func setSessionConfigOption(
    sessionID: String,
    configID: String,
    value: String
  ) async throws -> [OpenCodeACPConfigOption] {
    try requireInitialized()
    try validateIdentifier(sessionID)
    try requireSession(sessionID)
    try validateIdentifier(configID)
    guard !value.isEmpty, value.utf8.count <= 256,
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AgentRuntimeError.invalidRequest("session.config.value")
    }
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

  public func prompt(sessionID: String, text: String) async throws -> OpenCodeACPPromptResult {
    try requireInitialized()
    try validateIdentifier(sessionID)
    try requireSession(sessionID)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 32 * 1_024,
      !text.contains("\0")
    else {
      throw AgentRuntimeError.invalidRequest("prompt.text")
    }
    try beginSessionOperation()
    defer { endSessionOperation() }

    // ACP session/prompt resolves only when the whole turn finishes, so it
    // runs under the long lifetime budget instead of the per-RPC timeout.
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
      timeout: .seconds(24 * 60 * 60)
    )
    guard let stopReason = response.value["stopReason"]?.stringValue,
      !stopReason.isEmpty,
      stopReason.utf8.count <= 128,
      !stopReason.contains("\0")
    else {
      throw OpenCodeACPError.malformedResponse
    }
    return OpenCodeACPPromptResult(
      stopReason: stopReason,
      eventSequenceBarrier: response.eventSequenceBarrier
    )
  }

  public func cancel(sessionID: String) async throws {
    try requireInitialized()
    try validateIdentifier(sessionID)
    try requireSession(sessionID)
    try await send(
      ACPWireMessage(
        method: "session/cancel",
        params: .object(["sessionId": .string(sessionID)])
      )
    )
  }

  public func closeSession(id: String) async throws {
    try requireInitialized()
    try validateIdentifier(id)
    try requireSession(id)
    try beginSessionOperation()
    defer { endSessionOperation() }

    _ = try await request(
      method: "session/close",
      params: .object(["sessionId": .string(id)])
    )
    activeSessionID = nil
  }

  public func shutdown() async {
    guard !closed else { return }
    closed = true
    requestBroker.failAll(with: OpenCodeACPError.transportClosed)
    initializationTask?.cancel()
    initializationTask = nil
    activeSessionID = nil
    readerTask?.cancel()
    readerTask = nil
    pendingPermissions.removeAll()
    eventContinuation.finish()
    await requestBroker.close()
  }
}
