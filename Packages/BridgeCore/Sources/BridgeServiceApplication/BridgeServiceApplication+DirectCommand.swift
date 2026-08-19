import BridgeDirectCommand
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceDirectExecCommand(
    _ request: MCPDirectExecRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt {
    try Self.checkDeadline(deadline)
    guard request.timeoutMS > 0, request.timeoutMS <= 3_600_000,
      request.yieldTimeMS >= 0, request.yieldTimeMS <= 60_000
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    let project = try await readableProject(request.projectID)
    guard project.accessPolicy.write != .denied else {
      throw BridgeMCPQueryError.writeNotAllowed
    }
    let resolution = commandPolicy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id,
        commandID: request.commandID,
        argv: request.argv,
        workingDirectory: request.workingDirectory,
        requiresNetwork: false
      )
    )
    guard resolution.allowed else {
      throw BridgeMCPQueryError.commandDenied(Self.denialMessage(resolution.reason))
    }
    if resolution.requiresApproval {
      try await requireDirectApproval(
        project: project,
        kind: resolution.requiresNetwork ? .network : .command,
        summary: "Run \(request.commandID ?? resolution.argv.joined(separator: " "))",
        payload: request,
        clientRequestID: request.clientRequestID
      )
    }
    let workingDirectory = try Self.resolvedWorkingDirectory(
      project: project,
      relative: request.workingDirectory
    )
    let sessionID = "dcmd-\(UUID().uuidString)"
    let lease = try await acquireDirectLease(
      project: project,
      owner: .directCommand(sessionID: sessionID)
    )
    do {
      _ = try await directCommands.launch(
        sessionID: sessionID,
        projectID: project.id,
        argv: resolution.argv,
        workingDirectory: workingDirectory,
        requiresNetwork: resolution.requiresNetwork,
        usePTY: request.tty,
        timeout: .milliseconds(request.timeoutMS),
        onExit: { await lease.release() }
      )
      let yieldDeadline = ContinuousClock.now.advanced(by: .milliseconds(request.yieldTimeMS))
      while ContinuousClock.now < yieldDeadline {
        try? await Task.sleep(for: .milliseconds(20))
      }
      return try await receipt(for: sessionID)
    } catch {
      await lease.release()
      throw Self.publicCommandError(error)
    }
  }

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
    try Self.checkDeadline(deadline)
    guard !sessionID.isEmpty, sessionID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    guard data.utf8.count <= 64 * 1_024 else {
      throw BridgeMCPQueryError.contractRejected
    }
    do {
      try await directCommands.writeStdin(sessionID: sessionID, data: Data(data.utf8))
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

  private func receipt(for sessionID: String) async throws -> MCPDirectCommandReceipt {
    guard let session = await directCommands.snapshot(sessionID: sessionID) else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    return MCPDirectCommandReceipt(
      sessionID: session.sessionID,
      status: session.status,
      exitCode: session.exitCode.map(Int.init),
      startedAt: iso8601.string(from: session.startedAt),
      output: Self.output(session)
    )
  }

  private static func output(_ session: DirectCommandSession) -> MCPDirectCommandOutput {
    MCPDirectCommandOutput(
      sessionID: session.sessionID,
      status: session.status,
      exitCode: session.exitCode.map(Int.init),
      timedOut: session.timedOut,
      head: safe(session.output.head, maximum: 16 * 1_024),
      tail: safe(session.output.tail, maximum: 64 * 1_024),
      byteCount: session.output.byteCount,
      truncated: session.output.truncated
    )
  }

  static func resolvedWorkingDirectory(
    project: ServiceProjectRecord,
    relative: String?
  ) throws -> String {
    guard let relative, !relative.isEmpty else { return project.root.canonicalPath }
    let secure: SecureRelativePath
    do {
      secure = try SecureRelativePath(relative)
    } catch {
      throw BridgeMCPQueryError.pathDenied
    }
    return project.root.canonicalPath + "/" + secure.components.joined(separator: "/")
  }

  static func denialMessage(_ reason: DirectCommandDenialReason?) -> String {
    switch reason {
    case .commandModeDenied: "direct commands are disabled for this project"
    case .commandNotRegistered: "command is not registered for this project"
    case .invalidArguments: "invalid command arguments"
    case .unknownCommand: "unknown command"
    case .networkNotAllowed: "network access is not allowed for this project"
    case .writeNotAllowed: "project write access is denied"
    case .blacklisted: "command is blacklisted for this project"
    case nil: "command denied"
    }
  }

  static func publicCommandError(_ error: Error) -> BridgeMCPQueryError {
    switch error {
    case let error as DirectCommandSessionError:
      switch error {
      case .sessionNotFound, .notRunning:
        return .commandSessionNotFound
      case .projectBusy:
        return .busy
      case .invalidStdin:
        return .contractRejected
      }
    case let error as DirectProcessError:
      switch error {
      case .invalidArgument:
        return .contractRejected
      case .processLaunchFailed:
        return .unavailable
      case .stdinUnavailable:
        return .commandSessionNotFound
      }
    default:
      return .unavailable
    }
  }
}
