import BridgeDirectCommand
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

private struct DirectCommandApprovalPayload: Encodable {
  let request: MCPDirectExecRequest
  let resolvedArgv: [String]
  let executableIdentity: DirectExecutableIdentity?
}

private struct DirectExecutableIdentity: Codable, Equatable, Sendable {
  let device: UInt64
  let inode: UInt64

  static func read(atPath path: String) -> DirectExecutableIdentity? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    else { return nil }
    return DirectExecutableIdentity(device: device, inode: inode)
  }
}

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
    let project = try await writableProject(request.projectID)
    let resolvedExecutable = Self.resolvedExecutableForPolicy(
      request: request,
      project: project
    )
    let resolution = commandPolicy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id,
        commandID: request.commandID,
        argv: request.argv,
        resolvedExecutable: resolvedExecutable,
        workingDirectory: request.workingDirectory,
        requiresNetwork: requiresNetwork,
        isValidatedSkillScript: isValidatedSkillScript
      )
    )
    guard resolution.allowed else {
      throw BridgeMCPQueryError.commandDenied(Self.denialMessage(resolution.reason))
    }
    let workingDirectory = try Self.resolvedWorkingDirectory(
      project: project,
      relative: resolution.workingDirectory
    )
    let launchArgv = try Self.resolvedLaunchArgv(resolution.argv, project: project)
    let approvalPayload = DirectCommandApprovalPayload(
      request: request,
      resolvedArgv: launchArgv,
      executableIdentity: launchArgv.first.flatMap(DirectExecutableIdentity.read(atPath:))
    )
    try await requireDirectApproval(
      project: project,
      kind: resolution.requiresNetwork ? .network : .command,
      summary: "Run \(launchArgv.joined(separator: " "))",
      payload: approvalPayload,
      clientRequestID: request.clientRequestID
    )
    guard
      approvalPayload.resolvedArgv == launchArgv,
      approvalPayload.executableIdentity
        == launchArgv.first.flatMap(DirectExecutableIdentity.read(atPath:))
    else {
      throw BridgeMCPQueryError.pathChanged
    }
    let sessionID = "dcmd-\(UUID().uuidString)"
    let lease = try await acquireDirectLease(
      project: project,
      owner: .directCommand(sessionID: sessionID)
    )
    var launched = false
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
      launched = true
      let requestedYieldDeadline = ContinuousClock.now.advanced(
        by: .milliseconds(request.yieldTimeMS)
      )
      let yieldDeadline = requestedYieldDeadline < deadline ? requestedYieldDeadline : deadline
      while ContinuousClock.now < yieldDeadline {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(20))
      }
      try Self.checkDeadline(deadline)
      return try await receipt(for: sessionID)
    } catch is CancellationError {
      if launched { await stopDirectSession(sessionID) }
      await lease.release()
      throw CancellationError()
    } catch let error as BridgeMCPQueryError {
      if launched { await stopDirectSession(sessionID) }
      await lease.release()
      throw error
    } catch {
      if launched { await stopDirectSession(sessionID) }
      await lease.release()
      throw Self.publicCommandError(error)
    }
  }

  private func stopDirectSession(_ sessionID: String) async {
    try? await directCommands.interrupt(sessionID: sessionID)
  }

  private static func resolvedExecutableForPolicy(
    request: MCPDirectExecRequest,
    project: ServiceProjectRecord
  ) -> String? {
    let requestedExecutable =
      request.argv.first
      ?? request.commandID.flatMap { commandID in
        project.workspaceCommands.first(where: { $0.id == commandID })?.executable
      }
    guard let requestedExecutable, !requestedExecutable.isEmpty else { return nil }
    guard let resolved = try? resolvedLaunchArgv([requestedExecutable], project: project).first,
      Self.isAbsoluteExecutablePath(resolved)
    else { return nil }
    return resolved
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
    if Self.isAbsoluteExecutablePath(executable) {
      #if canImport(WinSDK)
        guard !executable.hasPrefix("\\\\") else {
          throw BridgeMCPQueryError.pathDenied
        }
      #endif
      let rootURL = URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
      let candidate = URL(fileURLWithPath: executable).standardizedFileURL
      let lexical = candidate.path
      let rootPath = rootURL.path
      // Trusted system binaries and full-mode absolute executables remain
      // valid.  An absolute path lexically inside the project is different:
      // resolve it before launch so a project-local symlink cannot escape.
      guard Self.path(lexical, isContainedBy: rootPath) else { return argv }
      let resolved = try containedResolvedPath(candidate, root: rootPath)
      return [resolved] + argv.dropFirst()
    }
    if executable.contains("/") || executable.contains("\\") {
      let root = project.root.canonicalPath
      let candidate =
        ((root as NSString).appendingPathComponent(executable) as NSString).standardizingPath
      let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
      guard Self.path(resolved, isContainedBy: root) else {
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
    #if canImport(WinSDK)
      let environment = ProcessInfo.processInfo.environment
      let systemRoot =
        environment.first { $0.key.caseInsensitiveCompare("SystemRoot") == .orderedSame }?.value
        ?? #"C:\Windows"#
      let programFiles =
        environment.first {
          $0.key.caseInsensitiveCompare("ProgramFiles") == .orderedSame
        }?.value ?? #"C:\Program Files"#
      let localAppData = environment.first {
        $0.key.caseInsensitiveCompare("LOCALAPPDATA") == .orderedSame
      }?.value
      return [
        URL(fileURLWithPath: systemRoot).appendingPathComponent("System32").path,
        systemRoot,
        URL(fileURLWithPath: programFiles).appendingPathComponent("Git/cmd").path,
        URL(fileURLWithPath: programFiles).appendingPathComponent("Git/bin").path,
        URL(fileURLWithPath: programFiles).appendingPathComponent("PowerShell/7").path,
        URL(fileURLWithPath: programFiles).appendingPathComponent("nodejs").path,
        localAppData.map {
          URL(fileURLWithPath: $0).appendingPathComponent("Programs/Git/cmd").path
        },
      ].compactMap { $0 }
    #else
      return [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
      ]
    #endif
  }

  static func executableInTrustedPath(_ name: String) -> String? {
    guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name.utf8.count <= 4_096
    else { return nil }
    #if canImport(WinSDK)
      let candidates =
        URL(fileURLWithPath: name).pathExtension.isEmpty ? [name, name + ".exe"] : [name]
    #else
      let candidates = [name]
    #endif
    for directory in trustedPathDirectories {
      for name in candidates {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        #if canImport(WinSDK)
          var isDirectory: ObjCBool = false
          if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
            !isDirectory.boolValue
          {
            return candidate
          }
        #else
          if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
          }
        #endif
      }
    }
    return nil
  }

  private static func containedResolvedPath(_ candidate: URL, root: String) throws -> String {
    let rootPath = URL(fileURLWithPath: root, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    guard Self.path(resolved, isContainedBy: rootPath) else {
      throw BridgeMCPQueryError.pathDenied
    }
    return resolved
  }

  private static func isAbsoluteExecutablePath(_ path: String) -> Bool {
    #if canImport(WinSDK)
      let units = Array(path.utf16)
      return path.hasPrefix("\\\\")
        || (units.count >= 3 && units[1] == 0x3A && (units[2] == 0x5C || units[2] == 0x2F))
    #else
      return path.hasPrefix("/")
    #endif
  }

  private static func path(_ candidate: String, isContainedBy root: String) -> Bool {
    #if canImport(WinSDK)
      let normalizedCandidate = candidate.replacingOccurrences(of: "/", with: "\\")
        .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
      let normalizedRoot = root.replacingOccurrences(of: "/", with: "\\")
        .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
      return normalizedCandidate.caseInsensitiveCompare(normalizedRoot) == .orderedSame
        || normalizedCandidate.lowercased().hasPrefix(normalizedRoot.lowercased() + "\\")
    #else
      return candidate == root || candidate.hasPrefix(root + "/")
    #endif
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

  static func mcpEnvironment(
    _ environment: DirectExecutionEnvironmentCapabilities
  ) -> MCPExecutionEnvironment {
    let directDefault = environment.commandEnvironment(denyNetwork: true)
    return MCPExecutionEnvironment(
      bridgeSandbox: directDefault.bridgeSandbox,
      scope: "direct_default",
      sandboxExec: directDefault.sandboxExec,
      nestedSandbox: directDefault.nestedSandbox,
      loopback: directDefault.loopback,
      childNetworkPolicy: "denied_by_default",
      xcodebuildNestedSandbox: directDefault.xcodebuildNestedSandbox,
      loopbackBind: directDefault.loopbackBind,
      limitations: directDefault.limitations
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
