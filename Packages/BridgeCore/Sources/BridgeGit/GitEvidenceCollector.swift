import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

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
      rootIdentity: root.identity,
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
      baseline.canonicalRootPath == root.url.path,
      baseline.rootIdentity == root.identity
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
    var confirmationPatch: GitPatchHandle?
    do {
      let confirmedStatus = try await captureStatus(at: root)
      guard confirmedStatus == status else {
        throw GitEvidenceError.repositoryChangedDuringCapture
      }
      let confirmedDiffStat = try await captureDiffStat(
        at: root,
        hasHead: confirmedStatus.headCommit != nil
      )
      guard confirmedDiffStat == diffStat else {
        throw GitEvidenceError.repositoryChangedDuringCapture
      }
      confirmationPatch = try await capturePatch(at: root, hasHead: status.headCommit != nil)
      guard try await patchesMatch(patch, confirmationPatch) else {
        throw GitEvidenceError.repositoryChangedDuringCapture
      }
      try root.validatePathIdentity()
    } catch {
      if let patch { await patchStore.discard(patch) }
      if let confirmationPatch { await patchStore.discard(confirmationPatch) }
      throw error
    }
    if let confirmationPatch { await patchStore.discard(confirmationPatch) }
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
    #if os(Windows)
      // Windows paths carry drive letters instead of a leading slash.
      guard provided.isFileURL else {
        throw GitEvidenceError.invalidAuthorizedRoot
      }
    #else
      guard provided.isFileURL, provided.path.hasPrefix("/") else {
        throw GitEvidenceError.invalidAuthorizedRoot
      }
    #endif
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
    #if os(Windows)
      let files = try scanner.scan(rootPath: root.url.path)
    #else
      let files = try scanner.scan(rootDescriptor: root.descriptor)
    #endif
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

  #if os(Windows)
    private func readAttributeFile(_ file: URL) throws -> Data {
      let handle: HANDLE = file.path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard handle != INVALID_HANDLE_VALUE else { throw GitEvidenceError.unsafeGitAttributes }
      defer { _ = CloseHandle(handle) }
      var information = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &information),
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else {
        throw GitEvidenceError.unsafeGitAttributes
      }
      let size = (UInt64(information.nFileSizeHigh) << 32) | UInt64(information.nFileSizeLow)
      guard size <= UInt64(256 * 1_024) else { throw GitEvidenceError.unsafeGitAttributes }
      var output = Data()
      var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
      while true {
        var received: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &received, nil)
        }
        guard succeeded else { throw GitEvidenceError.unsafeGitAttributes }
        if received == 0 { return output }
        output.append(contentsOf: buffer.prefix(Int(received)))
      }
    }
  #else
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
  #endif

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
      allowTruncation: false
    )
    guard !result.bytes.isEmpty else { return nil }
    return try await patchStore.store(result.bytes, isTruncated: false)
  }

  private func patchesMatch(
    _ first: GitPatchHandle?,
    _ second: GitPatchHandle?
  ) async throws -> Bool {
    switch (first, second) {
    case (nil, nil):
      return true
    case (.some(let first), .some(let second)):
      guard first.totalBytes == second.totalBytes,
        first.isTruncated == second.isTruncated
      else { return false }
      let firstDigest = try await patchDigest(first)
      let secondDigest = try await patchDigest(second)
      return firstDigest == secondDigest
    case (.none, .some), (.some, .none):
      return false
    }
  }

  private func patchDigest(_ handle: GitPatchHandle) async throws -> SHA256.Digest {
    var hasher = SHA256()
    var offset = 0
    while true {
      let page = try await patchStore.page(for: handle, offset: offset)
      hasher.update(data: page.bytes)
      guard let next = page.nextOffset else { return hasher.finalize() }
      offset = next
    }
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
    #if os(Windows)
      // Git for Windows resolves through PATH; there is no /usr/bin/git.
      let executableURL = URL(fileURLWithPath: "git")
    #else
      let executableURL = URL(fileURLWithPath: "/usr/bin/git")
    #endif
    do {
      return try await runner.run(
        BoundedProcessConfiguration(
          executableURL: executableURL,
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

  #if os(Windows)
    private static let gitEnvironment: [String] = {
      var environment = [
        "LANG=C",
        "LC_ALL=C",
        "GIT_CONFIG_NOSYSTEM=1",
        // Windows has no /dev/null; the NUL device fills the same role.
        "GIT_CONFIG_GLOBAL=NUL",
        "GIT_ATTR_NOSYSTEM=1",
        "GIT_OPTIONAL_LOCKS=0",
        "GIT_TERMINAL_PROMPT=0",
        "GIT_PAGER=cat",
        "PAGER=cat",
      ]
      let processEnvironment = ProcessInfo.processInfo.environment
      for key in ["PATH", "SystemRoot", "SystemDrive", "TEMP", "TMP", "COMSPEC"] {
        if let value = processEnvironment[key] {
          environment.append("\(key)=\(value)")
        }
      }
      return environment
    }()
  #else
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
  #endif
}
