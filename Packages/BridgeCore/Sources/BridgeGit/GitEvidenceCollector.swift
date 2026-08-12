import Darwin
import Foundation

public struct GitEvidenceCollector: Sendable {
  public let patchStore: GitPatchStore

  private let rootAuthorizer: any GitProjectRootAuthorizing
  private let limits: GitEvidenceLimits
  private let runner = BoundedProcessRunner()

  public init(
    rootAuthorizer: any GitProjectRootAuthorizing,
    limits: GitEvidenceLimits = .init(),
    patchStore: GitPatchStore? = nil
  ) {
    self.rootAuthorizer = rootAuthorizer
    self.limits = limits
    self.patchStore =
      patchStore
      ?? GitPatchStore(maximumPageBytes: limits.maximumPatchPageBytes)
  }

  public func captureBaseline(projectIdentifier: String) async throws -> GitBaselineEvidence {
    let root = try await authorizedRoot(for: projectIdentifier)
    let status = try await captureStatus(at: root)
    try root.validatePathIdentity()
    return GitBaselineEvidence(
      projectIdentifier: projectIdentifier,
      canonicalRootPath: root.url.path,
      capturedAt: Date(),
      status: status,
      changeAttribution: attribution(for: status)
    )
  }

  public func captureFinal(
    projectIdentifier: String,
    baseline: GitBaselineEvidence
  ) async throws -> GitFinalEvidence {
    let root = try await authorizedRoot(for: projectIdentifier)
    guard baseline.projectIdentifier == projectIdentifier,
      baseline.canonicalRootPath == root.url.path
    else {
      throw GitEvidenceError.baselineProjectMismatch
    }

    let status = try await captureStatus(at: root)
    guard status.repositoryClassification == .gitWorkingTree else {
      try root.validatePathIdentity()
      return GitFinalEvidence(
        projectIdentifier: projectIdentifier,
        canonicalRootPath: root.url.path,
        capturedAt: Date(),
        status: status,
        diffStat: "",
        changedFiles: [],
        untrackedFiles: [],
        patch: nil,
        changeAttribution: .unavailableForNonGitProject
      )
    }

    let diffStat = try await captureDiffStat(at: root, hasHead: status.headCommit != nil)
    let patch = try await capturePatch(at: root, hasHead: status.headCommit != nil)
    do {
      let confirmedStatus = try await captureStatus(at: root)
      guard confirmedStatus == status else {
        throw GitEvidenceError.repositoryChangedDuringCapture
      }
      try root.validatePathIdentity()
    } catch {
      if let patch { await patchStore.discard(patch) }
      throw error
    }
    return GitFinalEvidence(
      projectIdentifier: projectIdentifier,
      canonicalRootPath: root.url.path,
      capturedAt: Date(),
      status: status,
      diffStat: String(decoding: diffStat, as: UTF8.self),
      changedFiles: Array(Set(status.entries.map(\.path))).sorted(),
      untrackedFiles: status.entries.filter { $0.kind == .untracked }.map(\.path).sorted(),
      patch: patch,
      changeAttribution: finalAttribution(baseline: baseline, finalStatus: status)
    )
  }

  private func authorizedRoot(
    for projectIdentifier: String
  ) async throws -> OpenedWorkingDirectory {
    let provided = try await rootAuthorizer.authorizedCanonicalGitRoot(
      for: projectIdentifier)
    guard provided.isFileURL, provided.path.hasPrefix("/") else {
      throw GitEvidenceError.invalidAuthorizedRoot
    }
    let standardized = provided.standardizedFileURL
    let canonical = standardized.resolvingSymlinksInPath()
    guard standardized.path == canonical.path else {
      throw GitEvidenceError.invalidAuthorizedRoot
    }
    return try OpenedWorkingDirectory(canonicalURL: canonical)
  }

  private func captureStatus(at root: OpenedWorkingDirectory) async throws -> GitStatusEvidence {
    guard try await isGitWorkingTree(at: root) else { return .notGitRepository }
    try await requireSafeRepositoryConfiguration(at: root)
    try await requireRepositoryTopLevel(at: root)
    try await requireSafeAttributes(at: root)
    let result = try await runGit(
      [
        "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all",
        "--ignore-submodules=all",
      ],
      at: root,
      maximumStandardOutputBytes: limits.maximumStatusBytes
    )
    try requireSuccess(result)
    return try GitStatusParser(
      maximumFileCount: limits.maximumFileCount,
      maximumPathBytes: limits.maximumPathBytes,
      maximumAggregatePathBytes: limits.maximumAggregatePathBytes
    ).parse(result.standardOutput)
  }

  private func isGitWorkingTree(at root: OpenedWorkingDirectory) async throws -> Bool {
    let result = try await runGit(
      ["rev-parse", "--is-inside-work-tree"],
      at: root,
      maximumStandardOutputBytes: 64
    )
    if case .exited(0) = result.termination {
      return result.standardOutput == Data("true\n".utf8)
    }
    if isNotGitDiagnostic(result.standardError) { return false }
    try requireSuccess(result)
    throw GitEvidenceError.malformedGitOutput
  }

  private func requireRepositoryTopLevel(at root: OpenedWorkingDirectory) async throws {
    let result = try await runGit(
      ["rev-parse", "--show-prefix"],
      at: root,
      maximumStandardOutputBytes: limits.maximumPathBytes + 1
    )
    try requireSuccess(result)
    guard result.standardOutput == Data("\n".utf8) else {
      throw GitEvidenceError.repositoryRootMismatch
    }
  }

  private func requireSafeRepositoryConfiguration(
    at root: OpenedWorkingDirectory
  ) async throws {
    let result = try await runGit(
      [
        "config", "--local", "--no-includes", "--null", "--list",
      ],
      at: root,
      maximumStandardOutputBytes: limits.maximumStatusBytes
    )
    try requireSuccess(result)
    let keys = result.standardOutput.split(separator: 0, omittingEmptySubsequences: true).map {
      String(decoding: $0.prefix(while: { $0 != UInt8(ascii: "\n") }), as: UTF8.self)
        .lowercased()
    }
    guard !keys.contains(where: isUnsafeConfigurationKey) else {
      throw GitEvidenceError.unsafeRepositoryConfiguration
    }
  }

  private func isUnsafeConfigurationKey(_ key: String) -> Bool {
    if key.hasPrefix("filter.") || key.hasPrefix("include.")
      || key.hasPrefix("includeif.")
    {
      return true
    }
    if key == "core.attributesfile" || key == "core.fsmonitor" { return true }
    guard key.hasPrefix("diff.") else { return false }
    return key.hasSuffix(".command") || key.hasSuffix(".textconv")
  }

  private func requireSafeAttributes(at root: OpenedWorkingDirectory) async throws {
    var scanner = GitAttributeScanner()
    let files = try scanner.scan(rootDescriptor: root.descriptor)
    let informationFile = try await gitInformationAttributes(at: root)
    var totalBytes = 0
    for contents in files {
      guard totalBytes <= 1_024 * 1_024 - contents.count else {
        throw GitEvidenceError.commandOutputLimitExceeded
      }
      totalBytes += contents.count
      guard !containsFilterAttribute(contents) else {
        throw GitEvidenceError.unsafeGitAttributes
      }
    }
    if let informationFile {
      let contents = try readAttributeFile(informationFile)
      guard totalBytes <= 1_024 * 1_024 - contents.count else {
        throw GitEvidenceError.commandOutputLimitExceeded
      }
      guard !containsFilterAttribute(contents) else {
        throw GitEvidenceError.unsafeGitAttributes
      }
    }
  }

  private func gitInformationAttributes(
    at root: OpenedWorkingDirectory
  ) async throws -> URL? {
    let result = try await runGit(
      ["rev-parse", "--path-format=absolute", "--git-path", "info/attributes"],
      at: root,
      maximumStandardOutputBytes: limits.maximumPathBytes + 1
    )
    try requireSuccess(result)
    let path = String(decoding: result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .newlines)
    guard !path.isEmpty, path.utf8.count <= limits.maximumPathBytes else {
      throw GitEvidenceError.malformedGitOutput
    }
    let file = URL(fileURLWithPath: path).standardizedFileURL
    return FileManager.default.fileExists(atPath: file.path) ? file : nil
  }

  private func readAttributeFile(_ file: URL) throws -> Data {
    let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw GitEvidenceError.unsafeGitAttributes }
    defer { Darwin.close(descriptor) }
    var information = stat()
    guard fstat(descriptor, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG,
      information.st_size >= 0,
      information.st_size <= 256 * 1_024
    else {
      throw GitEvidenceError.unsafeGitAttributes
    }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while output.count <= 256 * 1_024 {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { return output }
      if count > 0 {
        output.append(contentsOf: buffer.prefix(count))
        continue
      }
      if errno == EINTR { continue }
      throw GitEvidenceError.unsafeGitAttributes
    }
    throw GitEvidenceError.unsafeGitAttributes
  }

  private func containsFilterAttribute(_ data: Data) -> Bool {
    let text = String(decoding: data, as: UTF8.self)
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let fields = line.split(whereSeparator: \.isWhitespace)
      for field in fields.dropFirst() {
        let token = field.trimmingCharacters(in: CharacterSet(charactersIn: "-!"))
        if token == "filter" || token.hasPrefix("filter=") { return true }
      }
    }
    return false
  }

  private func captureDiffStat(
    at root: OpenedWorkingDirectory,
    hasHead: Bool
  ) async throws -> Data {
    let commands = diffCommands(hasHead: hasHead, stat: true)
    let result = try await runCombinedGit(
      commands,
      at: root,
      maximumStandardOutputBytes: limits.maximumDiffStatBytes,
      allowTruncation: false
    )
    return result.bytes
  }

  private func capturePatch(
    at root: OpenedWorkingDirectory,
    hasHead: Bool
  ) async throws -> GitPatchHandle? {
    let commands = diffCommands(
      hasHead: hasHead,
      stat: false
    )
    let result = try await runCombinedGit(
      commands,
      at: root,
      maximumStandardOutputBytes: limits.maximumPatchBytes,
      allowTruncation: true
    )
    guard !result.bytes.isEmpty || result.isTruncated else { return nil }
    return try await patchStore.store(result.bytes, isTruncated: result.isTruncated)
  }

  private func diffCommands(hasHead: Bool, stat: Bool) -> [[String]] {
    let options =
      ["--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=all"]
      + (stat ? ["--stat"] : [])
    if hasHead { return [["diff"] + options + ["HEAD", "--"]] }
    return [
      ["diff"] + options + ["--cached", "--"],
      ["diff"] + options + ["--"],
    ]
  }

  private func runCombinedGit(
    _ commands: [[String]],
    at root: OpenedWorkingDirectory,
    maximumStandardOutputBytes: Int,
    allowTruncation: Bool
  ) async throws -> (bytes: Data, isTruncated: Bool) {
    var combined = Data()
    for command in commands {
      let remaining = maximumStandardOutputBytes - combined.count
      guard remaining > 0 else {
        if allowTruncation { return (combined, true) }
        throw GitEvidenceError.commandOutputLimitExceeded
      }
      let result = try await runGit(
        command,
        at: root,
        maximumStandardOutputBytes: remaining
      )
      if case .outputLimit = result.termination {
        guard allowTruncation, result.standardErrorTruncated == false else {
          throw GitEvidenceError.commandOutputLimitExceeded
        }
        combined.append(result.standardOutput)
        return (combined, true)
      }
      try requireSuccess(result)
      combined.append(result.standardOutput)
    }
    return (combined, false)
  }

  private func runGit(
    _ command: [String],
    at root: OpenedWorkingDirectory,
    maximumStandardOutputBytes: Int
  ) async throws -> BoundedProcessResult {
    let globalArguments = [
      "--no-pager", "--no-optional-locks", "-c", "core.quotepath=false", "-c",
      "color.ui=false", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
      "-c", "submodule.recurse=false",
    ]
    do {
      return try await runner.run(
        BoundedProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/usr/bin/git"),
          arguments: globalArguments + command,
          workingDirectory: root,
          environment: Self.gitEnvironment,
          timeout: limits.commandTimeout,
          terminationGracePeriod: limits.terminationGracePeriod,
          maximumStandardOutputBytes: maximumStandardOutputBytes,
          maximumStandardErrorBytes: limits.maximumStandardErrorBytes
        )
      )
    } catch BoundedProcessError.timedOut {
      throw GitEvidenceError.commandTimedOut
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw GitEvidenceError.commandLaunchFailed
    }
  }

  private func requireSuccess(_ result: BoundedProcessResult) throws {
    if case .outputLimit = result.termination {
      throw GitEvidenceError.commandOutputLimitExceeded
    }
    guard case .exited(let code) = result.termination else {
      throw GitEvidenceError.commandFailed(exitCode: 255, diagnostic: "unknown termination")
    }
    guard code == 0 else {
      let diagnostic = String(decoding: result.standardError, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw GitEvidenceError.commandFailed(exitCode: code, diagnostic: diagnostic)
    }
  }

  private func isNotGitDiagnostic(_ data: Data) -> Bool {
    String(decoding: data, as: UTF8.self).lowercased().contains("not a git repository")
  }

  private func attribution(for status: GitStatusEvidence) -> GitChangeAttribution {
    if status.repositoryClassification == .notGitRepository {
      return .unavailableForNonGitProject
    }
    return status.isDirty ? .mixedWithPreexistingChanges : .attributableFromCleanBaseline
  }

  private func finalAttribution(
    baseline: GitBaselineEvidence,
    finalStatus: GitStatusEvidence
  ) -> GitChangeAttribution {
    guard finalStatus.repositoryClassification == .gitWorkingTree,
      baseline.status.repositoryClassification == .gitWorkingTree
    else {
      return .unavailableForNonGitProject
    }
    return baseline.status.isDirty
      ? .mixedWithPreexistingChanges : .attributableFromCleanBaseline
  }

  private static let gitEnvironment = [
    "PATH=/usr/bin:/bin",
    "LANG=C",
    "LC_ALL=C",
    "GIT_CONFIG_NOSYSTEM=1",
    "GIT_CONFIG_GLOBAL=/dev/null",
    "GIT_ATTR_NOSYSTEM=1",
    "GIT_OPTIONAL_LOCKS=0",
    "GIT_TERMINAL_PROMPT=0",
    "GIT_PAGER=cat",
    "PAGER=cat",
  ]
}
