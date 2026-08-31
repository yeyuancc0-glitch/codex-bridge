import BridgeDirectCommand
import BridgeMCP
import BridgeSecurity
import Foundation

extension BridgeServiceApplication {
  public func serviceDirectReadCommand(
    sessionID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput {
    try Self.checkDeadline(deadline)
    guard !sessionID.isEmpty, sessionID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    guard let session = await directCommands.snapshot(sessionID: sessionID) else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    return Self.output(session)
  }

  public func serviceDirectWriteStdin(
    sessionID: String,
    data: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try await serviceDirectWriteStdin(
      sessionID: sessionID,
      data: data,
      closeStdin: false,
      deadline: deadline
    )
  }

  public func serviceDirectWriteStdin(
    sessionID: String,
    data: String,
    closeStdin: Bool,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    guard !sessionID.isEmpty, sessionID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    guard !data.isEmpty || closeStdin, data.utf8.count <= 64 * 1_024 else {
      throw BridgeMCPQueryError.contractRejected
    }
    do {
      try await directCommands.writeStdin(
        sessionID: sessionID,
        data: Data(data.utf8),
        closeStdin: closeStdin
      )
    } catch {
      throw Self.publicCommandError(error)
    }
  }

  public func serviceDirectInterruptCommand(
    sessionID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput {
    try Self.checkDeadline(deadline)
    guard !sessionID.isEmpty, sessionID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    guard let existing = await directCommands.snapshot(sessionID: sessionID) else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    if existing.status != "running" {
      return Self.output(existing)
    }
    do {
      try await directCommands.interrupt(sessionID: sessionID)
    } catch {
      throw Self.publicCommandError(error)
    }
    guard let session = await directCommands.snapshot(sessionID: sessionID) else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    return Self.output(session)
  }

  static func output(_ session: DirectCommandSession) -> MCPDirectCommandOutput {
    MCPDirectCommandOutput(
      sessionID: session.sessionID,
      status: session.status,
      exitCode: session.exitCode.map(Int.init),
      timedOut: session.timedOut,
      commandStatus: session.status,
      commandTimedOut: session.timedOut,
      readTimeout: false,
      head: OutboundContentSecurity.redactedCommandOutput(
        session.output.head, maximumUTF8Bytes: 16 * 1_024),
      tail: OutboundContentSecurity.redactedCommandOutput(
        session.output.tail, maximumUTF8Bytes: 64 * 1_024),
      byteCount: session.output.byteCount,
      truncated: session.output.truncated,
      executionEnvironment: Self.mcpEnvironment(session.executionEnvironment)
    )
  }

  private static func mcpEnvironment(
    _ environment: DirectCommandExecutionEnvironment
  ) -> MCPExecutionEnvironment {
    MCPExecutionEnvironment(
      bridgeSandbox: environment.bridgeSandbox,
      scope: "direct_command",
      sandboxExec: environment.sandboxExec,
      nestedSandbox: environment.nestedSandbox,
      loopback: environment.loopback,
      childNetworkPolicy: environment.childNetworkPolicy,
      xcodebuildNestedSandbox: environment.xcodebuildNestedSandbox,
      loopbackBind: environment.loopbackBind,
      limitations: environment.limitations
    )
  }
}
