import BridgeDirectCommand
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import BridgeSkills
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

  public func serviceRunSkillAction(
    _ request: MCPRunSkillActionRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    guard request.arguments.count <= 128,
      request.arguments.allSatisfy({ $0.utf8.count <= 4_096 })
    else { throw BridgeMCPQueryError.contractRejected }
    let manifests: [SkillManifest]
    do {
      manifests = try await skillScanner.scanSkills(
        for: URL(fileURLWithPath: project.root.canonicalPath)
      )
    } catch {
      throw Self.publicSkillError(error)
    }
    guard let manifest = manifests.first(where: { $0.name == request.skillName }) else {
      throw BridgeMCPQueryError.skillNotFound
    }
    let launch: SkillScanner.SkillActionLaunch
    do {
      launch = try await skillScanner.resolveAction(request.actionName, in: manifest)
    } catch {
      throw Self.publicSkillError(error)
    }
    let argv = launch.argvPrefix + request.arguments
    let requiresNetwork = launch.action.networkRequirement != .denied
    // Only an explicit denial enters the network sandbox. Unspecified actions
    // are conservatively treated as network-capable by project policy and local
    // approval; guessing `denied` would break legitimate loopback/network tools.
    let denyNetwork = launch.action.networkRequirement == .denied
    let directRequest = MCPDirectExecRequest(
      projectID: request.projectID,
      argv: argv,
      workingDirectory: nil,
      tty: false,
      yieldTimeMS: request.yieldTimeMS,
      timeoutMS: request.timeoutMS,
      clientRequestID: request.clientRequestID
    )
    return try await serviceDirectExecCommand(
      directRequest,
      deadline: deadline,
      isValidatedSkillScript: true,
      requiresNetwork: requiresNetwork,
      denyNetwork: denyNetwork
    )
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

  public func serviceDirectGitCommit(
    _ request: MCPDirectGitCommitRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectGitCommitReceipt {
    try Self.checkDeadline(deadline)
    let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, message.utf8.count <= 4_096, !message.contains("\0") else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard request.files.count <= 128 else { throw BridgeMCPQueryError.contractRejected }
    let project = try await readableProject(request.projectID)
    guard project.accessPolicy.write != .denied else {
      throw BridgeMCPQueryError.writeNotAllowed
    }
    if project.accessPolicy.write == .requiresLocalApproval {
      try await requireDirectApproval(
        project: project,
        kind: .command,
        summary: "Git commit: \(String(message.prefix(120)))",
        payload: request,
        clientRequestID: request.clientRequestID
      )
    }
    let operationID = "op-" + UUID().uuidString.lowercased()
    let lease = try await acquireDirectLease(
      project: project,
      owner: .directGitCommit(operationID: operationID)
    )
    do {
      let receipt = try await Self.runGitCommit(
        project: project,
        message: message,
        files: request.files,
        runner: DirectGitRunner()
      )
      await lease.release()
      return receipt
    } catch {
      await lease.release()
      throw Self.publicGitError(error)
    }
  }

  static func runGitCommit(
    project: ServiceProjectRecord,
    message: String,
    files: [String],
    runner: DirectGitRunner
  ) async throws -> MCPDirectGitCommitReceipt {
    let root = project.root.canonicalPath
    let git = DirectGitRunner.gitPath
    let temporaryIndex = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-bridge-git-index-\(UUID().uuidString)")
    let gitEnvironment = ["GIT_INDEX_FILE": temporaryIndex.path]
    defer {
      try? FileManager.default.removeItem(at: temporaryIndex)
      try? FileManager.default.removeItem(at: temporaryIndex.appendingPathExtension("lock"))
    }

    let verify = try await runner.run(
      argv: [git, "-C", root, "rev-parse", "--is-inside-work-tree"],
      workingDirectory: root
    )
    guard verify.exitCode == 0 else { throw DirectGitError.notGitRepository }

    // Build the commit from a private index.  The user's existing index may
    // contain unrelated staged work; committing through it would silently
    // widen an explicit `files` request.  A temporary index also means every
    // failure path leaves the user's staging area byte-for-byte untouched.
    let head = try await runner.run(
      argv: [git, "-C", root, "rev-parse", "--verify", "HEAD"],
      workingDirectory: root
    )
    let indexSeed = head.exitCode == 0 ? ["HEAD"] : ["--empty"]
    let seeded = try await runner.run(
      argv: [git, "-C", root, "read-tree"] + indexSeed,
      workingDirectory: root,
      environment: gitEnvironment
    )
    guard seeded.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(seeded.output))
    }

    if !files.isEmpty {
      try validateGitRelativePaths(files, root: root)
    }

    let stageArgv: [String]
    if files.isEmpty {
      stageArgv = [git, "-C", root, "add", "-A"]
    } else {
      stageArgv = [git, "-C", root, "add", "--"] + files
    }
    let staged = try await runner.run(
      argv: stageArgv,
      workingDirectory: root,
      environment: gitEnvironment
    )
    guard staged.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(staged.output))
    }

    let changedResult = try await runner.run(
      argv: [git, "-C", root, "diff", "--cached", "--name-only"],
      workingDirectory: root,
      environment: gitEnvironment
    )
    guard changedResult.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(changedResult.output))
    }
    let changedFiles = changedResult.output.tail
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !changedFiles.isEmpty else {
      return MCPDirectGitCommitReceipt(
        commitHash: nil,
        changedFiles: [],
        summary: "Nothing to commit; working tree is clean for the requested paths.",
        exitCode: 0
      )
    }
    try validateGitRelativePaths(changedFiles, root: root)

    let commit = try await runner.run(
      argv: [git, "-C", root, "commit", "-m", message],
      workingDirectory: root,
      environment: gitEnvironment
    )
    guard commit.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(commit.output))
    }
    let synchronizeIndexArgv =
      files.isEmpty
      ? [git, "-C", root, "add", "-A"]
      : [git, "-C", root, "add", "-A", "--"] + changedFiles
    let synchronized = try await runner.run(
      argv: synchronizeIndexArgv,
      workingDirectory: root
    )
    guard synchronized.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(synchronized.output))
    }
    let hashResult = try await runner.run(
      argv: [git, "-C", root, "rev-parse", "HEAD"],
      workingDirectory: root,
      environment: gitEnvironment
    )
    guard hashResult.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(hashResult.output))
    }
    let hash = hashResult.output.tail.split(separator: "\n").first.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let hash, hash.count == 40, hash.allSatisfy(\.isHexDigit) else {
      throw DirectGitCommitError.gitFailed("Git did not return the new commit identifier.")
    }
    return MCPDirectGitCommitReceipt(
      commitHash: hash,
      changedFiles: Array(changedFiles.prefix(128)),
      summary: Self.gitSummary(commit.output),
      exitCode: Int(commit.exitCode)
    )
  }

  private static func gitSummary(_ output: DirectCommandOutputBuffer) -> String {
    let tail = output.tail.trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? output.head.trimmingCharacters(in: .whitespacesAndNewlines) : tail
  }

  private static func validateGitRelativePaths(_ paths: [String], root: String) throws {
    let sensitive = SensitivePathPolicy()
    for value in paths {
      guard let relative = try? SecureRelativePath(value), sensitive.allows(relative) else {
        throw DirectGitError.invalidArgument
      }
      let requested = URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent(relative.value)
      let resolvedRoot = URL(fileURLWithPath: root, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath().path
      let resolved = requested.standardizedFileURL.resolvingSymlinksInPath().path
      guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
        throw DirectGitError.invalidArgument
      }
      let canonicalRelative = String(resolved.dropFirst(resolvedRoot.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if let canonical = try? SecureRelativePath(canonicalRelative) {
        guard sensitive.allows(canonical) else { throw DirectGitError.invalidArgument }
      }
      try validateGitFileContent(at: resolved)
    }
  }

  private static func validateGitFileContent(at path: String) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
      throw DirectGitError.invalidArgument
    }
    if let size = attributes[.size] as? NSNumber, size.intValue > 8 * 1_024 * 1_024 {
      throw DirectGitError.invalidArgument
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    guard let text = String(data: data, encoding: .utf8) else { return }
    guard OutboundContentSecurity.isSafeSecrets(text) else {
      throw DirectGitError.invalidArgument
    }
  }

  static func publicGitError(_ error: Error) -> BridgeMCPQueryError {
    switch error {
    case DirectGitError.notGitRepository:
      return .notGitRepository
    case DirectGitError.invalidArgument:
      return .contractRejected
    case DirectGitError.launchFailed:
      return .processLaunchFailed
    case DirectGitError.timedOut:
      return .commandTimeout
    case DirectGitCommitError.gitFailed(let summary):
      return .gitOperationFailed(summary)
    default:
      return .unavailable
    }
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
