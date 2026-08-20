import BridgeDirectCommand
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
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
    let project = try await approvedDirectProject(
      projectID: request.projectID,
      kind: .command,
      summary: "Git commit: \(String(message.prefix(120)))",
      payload: request,
      clientRequestID: request.clientRequestID
    )
    let operationID = "op-" + UUID().uuidString.lowercased()
    do {
      return try await withDirectLease(
        project: project,
        owner: .directGitCommit(operationID: operationID)
      ) {
        try await Self.runGitCommit(
          project: project,
          message: message,
          files: request.files,
          runner: DirectGitRunner()
        )
      }
    } catch {
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

    try await verifyGitRepository(root: root, git: git, runner: runner)
    try await preparePrivateIndex(
      root: root,
      git: git,
      runner: runner,
      environment: gitEnvironment
    )
    let changedFiles = try await stageAndEnumerateChangedFiles(
      root: root,
      git: git,
      files: files,
      runner: runner,
      environment: gitEnvironment
    )
    guard !changedFiles.isEmpty else {
      return MCPDirectGitCommitReceipt(
        commitHash: nil,
        changedFiles: [],
        summary: "Nothing to commit; working tree is clean for the requested paths.",
        exitCode: 0
      )
    }
    let indexTransaction = try await DirectGitIndexTransaction.begin(
      root: root,
      git: git,
      runner: runner,
    )
    defer { indexTransaction.cancel() }
    let commit = try await createCommit(
      root: root,
      git: git,
      message: message,
      runner: runner,
      environment: gitEnvironment
    )
    let hash = try await readCommitHash(
      root: root,
      git: git,
      runner: runner,
      environment: gitEnvironment
    )
    do {
      try await indexTransaction.synchronize(
        root: root,
        git: git,
        changedFiles: changedFiles,
        runner: runner
      )
    } catch {
      let synchronizationError = indexSynchronizationSummary(error)
      return MCPDirectGitCommitReceipt(
        commitHash: hash,
        changedFiles: Array(changedFiles.prefix(128)),
        summary:
          "\(gitSummary(commit.output)) Index synchronization warning: \(synchronizationError)",
        exitCode: Int(commit.exitCode),
        indexSynchronized: false,
        indexSynchronizationError: synchronizationError
      )
    }
    return MCPDirectGitCommitReceipt(
      commitHash: hash,
      changedFiles: Array(changedFiles.prefix(128)),
      summary: Self.gitSummary(commit.output),
      exitCode: Int(commit.exitCode)
    )
  }

  private static func verifyGitRepository(
    root: String,
    git: String,
    runner: DirectGitRunner
  ) async throws {
    let verify = try await runner.run(
      argv: [git, "-C", root, "rev-parse", "--is-inside-work-tree"],
      workingDirectory: root
    )
    guard verify.exitCode == 0 else { throw DirectGitError.notGitRepository }
  }

  private static func preparePrivateIndex(
    root: String,
    git: String,
    runner: DirectGitRunner,
    environment: [String: String]
  ) async throws {
    // A private index prevents unrelated staged work from widening the requested commit.
    let head = try await runner.run(
      argv: [git, "-C", root, "rev-parse", "--verify", "HEAD"],
      workingDirectory: root
    )
    let indexSeed = head.exitCode == 0 ? ["HEAD"] : ["--empty"]
    let seeded = try await runner.run(
      argv: [git, "-C", root, "read-tree"] + indexSeed,
      workingDirectory: root,
      environment: environment
    )
    guard seeded.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(seeded.output))
    }
  }

  private static func stageAndEnumerateChangedFiles(
    root: String,
    git: String,
    files: [String],
    runner: DirectGitRunner,
    environment: [String: String]
  ) async throws -> [String] {
    if !files.isEmpty {
      try validateGitRelativePaths(files, root: root)
    }
    let stageArgv =
      files.isEmpty
      ? [git, "-C", root, "add", "-A"]
      : [git, "-C", root, "add", "--"] + files
    let staged = try await runner.run(
      argv: stageArgv,
      workingDirectory: root,
      environment: environment
    )
    guard staged.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(staged.output))
    }

    let changedResult = try await runner.run(
      argv: [git, "-C", root, "diff", "--cached", "--name-only"],
      workingDirectory: root,
      environment: environment
    )
    guard changedResult.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(changedResult.output))
    }
    let changedFiles = changedResult.output.tail
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !changedFiles.isEmpty else { return [] }
    try validateGitRelativePaths(changedFiles, root: root)
    return changedFiles
  }

  private static func createCommit(
    root: String,
    git: String,
    message: String,
    runner: DirectGitRunner,
    environment: [String: String]
  ) async throws -> DirectGitResult {
    let commit = try await runner.run(
      argv: [git, "-C", root, "commit", "-m", message],
      workingDirectory: root,
      environment: environment
    )
    guard commit.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(Self.gitSummary(commit.output))
    }
    return commit
  }

  private static func readCommitHash(
    root: String,
    git: String,
    runner: DirectGitRunner,
    environment: [String: String]
  ) async throws -> String {
    let hashResult = try await runner.run(
      argv: [git, "-C", root, "rev-parse", "HEAD"],
      workingDirectory: root,
      environment: environment
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
    return hash
  }

  private static func gitSummary(_ output: DirectCommandOutputBuffer) -> String {
    let tail = output.tail.trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? output.head.trimmingCharacters(in: .whitespacesAndNewlines) : tail
  }

  private static func indexSynchronizationSummary(_ error: Error) -> String {
    if case DirectGitCommitError.gitFailed(let summary) = error {
      return String(summary.prefix(4_096))
    }
    switch error {
    case DirectGitError.launchFailed:
      return "The commit was created, but Git could not launch to synchronize the real index."
    case DirectGitError.timedOut:
      return "The commit was created, but real index synchronization timed out."
    default:
      return "The commit was created, but the real Git index could not be synchronized."
    }
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
}
