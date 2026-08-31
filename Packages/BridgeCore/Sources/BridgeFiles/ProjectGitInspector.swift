import BridgeAgentCore
import BridgeGit
import BridgeProjects
import BridgeSecurity
import Foundation

public struct ProjectGitInspector: Sendable {
  public init() {}

  public func changes(root: RegisteredRoot) async throws -> ProjectChangesResult {
    try root.validateCurrentIdentity()
    let workingDirectory = try OpenedWorkingDirectory(
      canonicalURL: URL(fileURLWithPath: root.canonicalPath, isDirectory: true))
    let git = try Self.gitExecutable()

    async let statusTask = runGit(
      git: git,
      workingDirectory: workingDirectory,
      arguments: ["status", "--porcelain=v1", "-z"]
    )
    async let diffTask = runGit(
      git: git,
      workingDirectory: workingDirectory,
      arguments: ["diff", "--no-ext-diff", "--no-color"]
    )
    async let cachedTask = runGit(
      git: git,
      workingDirectory: workingDirectory,
      arguments: ["diff", "--cached", "--no-ext-diff", "--no-color"]
    )
    let (status, diff, cached) = try await (statusTask, diffTask, cachedTask)
    let notGitRepository = isGitRepositoryFailure(status)
    let changedFiles = parseStatus(status)
    let combined = combine(diff.standardOutput, cached.standardOutput)
    let stats = diffStatistics(combined)
    let output = boundedOutput(combined)
    return ProjectChangesResult(
      changedFiles: changedFiles,
      diff: output.text,
      additions: stats.additions,
      deletions: stats.deletions,
      truncated: output.truncated,
      notGitRepository: notGitRepository
    )
  }

  private func isGitRepositoryFailure(_ result: BoundedProcessResult) -> Bool {
    if case .exited(let code) = result.termination {
      return code == 128
    }
    return false
  }

  private func runGit(
    git: String,
    workingDirectory: OpenedWorkingDirectory,
    arguments: [String]
  ) async throws -> BoundedProcessResult {
    try workingDirectory.validatePathIdentity()
    let runner = BoundedProcessRunner()
    return try await runner.run(
      BoundedProcessConfiguration(
        executableURL: URL(fileURLWithPath: git),
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: Self.gitEnvironment(),
        timeout: .seconds(10),
        terminationGracePeriod: .seconds(1),
        maximumStandardOutputBytes: 200 * 1_024,
        maximumStandardErrorBytes: 64 * 1_024
      )
    )
  }

  private static func gitExecutable() throws -> String {
    #if os(Windows)
      guard let path = AgentExecutableResolver().resolve("git") else {
        throw BoundedProcessError.launchFailed
      }
      return path
    #else
      return "/usr/bin/git"
    #endif
  }

  private static func gitEnvironment() -> [String] {
    #if os(Windows)
      let source = ProcessInfo.processInfo.environment
      let keys = [
        "SystemRoot", "WINDIR", "SystemDrive", "TEMP", "TMP", "USERPROFILE", "HOME",
        "LOCALAPPDATA", "APPDATA", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432",
        "PATH", "PATHEXT", "LANG", "LC_ALL",
      ]
      return keys.compactMap { key in
        guard
          let sourceKey = source.keys.first(where: {
            $0.caseInsensitiveCompare(key) == .orderedSame
          })
        else { return nil }
        return "\(key)=\(source[sourceKey] ?? "")"
      } + ["GIT_OPTIONAL_LOCKS=0"]
    #else
      return ["LANG=C", "LC_ALL=C", "GIT_OPTIONAL_LOCKS=0"]
    #endif
  }

  private func parseStatus(_ result: BoundedProcessResult) -> [String] {
    guard case .exited(let code) = result.termination, code == 0 else { return [] }
    let text = String(decoding: result.standardOutput, as: UTF8.self)
    return text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
  }

  private func combine(_ a: Data, _ b: Data) -> Data {
    guard !b.isEmpty else { return a }
    guard !a.isEmpty else { return b }
    var combined = a
    combined.append(Data("\n".utf8))
    combined.append(b)
    return combined
  }

  private func diffStatistics(_ data: Data) -> (additions: Int, deletions: Int) {
    let text = String(decoding: data, as: UTF8.self)
    var additions = 0
    var deletions = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("+") && !line.hasPrefix("+++") {
        additions += 1
      } else if line.hasPrefix("-") && !line.hasPrefix("---") {
        deletions += 1
      }
    }
    return (additions, deletions)
  }

  private func boundedOutput(_ data: Data) -> (text: String, truncated: Bool) {
    let maximumBytes = 200 * 1_024
    let truncated = data.count > maximumBytes
    let bounded = data.prefix(maximumBytes)
    guard let text = String(data: bounded, encoding: .utf8) else {
      return (String(decoding: bounded, as: UTF8.self), truncated)
    }
    return (text, truncated)
  }
}
