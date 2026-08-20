import BridgeDirectCommand
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  package func shutdownDirectOperations() async {
    await directCommands.cancelAll()
    await approvals.cancelAll()
  }

  public func serviceDirectExecCommand(
    _ request: MCPDirectExecRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt {
    try await serviceDirectExecCommand(
      request, deadline: deadline, isValidatedSkillScript: false, requiresNetwork: false,
      denyNetwork: false
    )
  }

  func serviceDirectExecCommand(
    _ request: MCPDirectExecRequest,
    deadline: ContinuousClock.Instant,
    isValidatedSkillScript: Bool,
    requiresNetwork: Bool,
    denyNetwork: Bool
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
        requiresNetwork: requiresNetwork,
        isValidatedSkillScript: isValidatedSkillScript
      )
    )
    guard resolution.allowed else {
      throw BridgeMCPQueryError.commandDenied(Self.denialMessage(resolution.reason))
    }
    try await requireDirectApproval(
      project: project,
      kind: resolution.requiresNetwork ? .network : .command,
      summary: "Run \(request.commandID ?? resolution.argv.joined(separator: " "))",
      payload: request,
      clientRequestID: request.clientRequestID
    )
    let workingDirectory = try Self.resolvedWorkingDirectory(
      project: project,
      relative: resolution.workingDirectory
    )
    let launchArgv = try Self.resolvedLaunchArgv(resolution.argv, project: project)
    let sessionID = "dcmd-\(UUID().uuidString)"
    let lease = try await acquireDirectLease(
      project: project,
      owner: .directCommand(sessionID: sessionID)
    )
    do {
      _ = try await directCommands.launch(
        sessionID: sessionID,
        projectID: project.id,
        argv: launchArgv,
        workingDirectory: workingDirectory,
        requiresNetwork: resolution.requiresNetwork,
        usePTY: request.tty,
        timeout: .milliseconds(request.timeoutMS),
        denyNetwork: denyNetwork || !resolution.requiresNetwork
          || project.accessPolicy.network == .denied,
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
    let root = project.root.canonicalPath
    guard let relative, !relative.isEmpty else { return root }
    var value = relative.trimmingCharacters(in: .whitespacesAndNewlines)
    if value == "." || value == "./" { return root }
    if value.hasPrefix("./") {
      value = String(value.dropFirst(2))
    }
    if value.isEmpty { return root }
    let secure: SecureRelativePath
    do {
      secure = try SecureRelativePath(value)
    } catch {
      throw BridgeMCPQueryError.pathDenied
    }
    let candidate = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent(secure.value, isDirectory: true)
    return try containedResolvedPath(candidate, root: root)
  }

  /// Resolve a project-relative executable (e.g. `Scripts/with-xcode.sh`) to an absolute path
  /// inside the project root (verifying symlink containment), or resolve a bare binary name
  /// (e.g. `git`) against a fixed trusted PATH. Absolute paths pass through unchanged.
  static func resolvedLaunchArgv(
    _ argv: [String],
    project: ServiceProjectRecord
  ) throws -> [String] {
    guard let executable = argv.first, !executable.isEmpty else { return argv }
    if executable.hasPrefix("/") {
      let rootURL = URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
      let candidate = URL(fileURLWithPath: executable).standardizedFileURL
      let lexical = candidate.path
      let rootPath = rootURL.path
      // Trusted system binaries and full-mode absolute executables remain
      // valid.  An absolute path lexically inside the project is different:
      // resolve it before launch so a project-local symlink cannot escape.
      guard lexical == rootPath || lexical.hasPrefix(rootPath + "/") else { return argv }
      let resolved = try containedResolvedPath(candidate, root: rootPath)
      return [resolved] + argv.dropFirst()
    }
    if executable.contains("/") {
      let root = project.root.canonicalPath
      let candidate =
        ((root as NSString).appendingPathComponent(executable) as NSString).standardizingPath
      let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
      guard resolved == root || resolved.hasPrefix(root + "/") else {
        throw BridgeMCPQueryError.pathDenied
      }
      return [resolved] + argv.dropFirst()
    }
    if let resolved = Self.executableInTrustedPath(executable) {
      return [resolved] + argv.dropFirst()
    }
    return argv
  }

  /// Fixed trusted PATH used to resolve bare binary names without invoking a shell.
  static var trustedPathDirectories: [String] {
    [
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
      "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
  }

  static func executableInTrustedPath(_ name: String) -> String? {
    guard !name.isEmpty, !name.contains("/"), name.utf8.count <= 4_096 else { return nil }
    for directory in trustedPathDirectories {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  private static func containedResolvedPath(_ candidate: URL, root: String) throws -> String {
    let rootPath = URL(fileURLWithPath: root, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
      throw BridgeMCPQueryError.pathDenied
    }
    return resolved
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
        return .processLaunchFailed
      case .stdinUnavailable:
        return .commandSessionNotFound
      case .sandboxUnavailable:
        return .networkIsolationUnavailable
      }
    default:
      return .unavailable
    }
  }
}
