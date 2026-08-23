#if canImport(WinSDK)
  import BridgeDirectCommand
  import BridgeProjects
  import BridgeSecurity
  import Foundation

  public struct ProjectGitInspector: Sendable {
    public init() {}

    public func changes(root: RegisteredRoot) async throws -> ProjectChangesResult {
      try root.validateCurrentIdentity()
      let git = try DirectGitRunner.resolveGitPath()
      let status = try await runGit(
        executable: git,
        root: root,
        arguments: ["status", "--porcelain=v1", "-z"]
      )
      let notGitRepository = status.exitCode == 128
      let changedFiles = parseStatus(status)
      let diff = try await runGit(
        executable: git,
        root: root,
        arguments: ["diff", "--no-ext-diff", "--no-color"]
      )
      let cached = try await runGit(
        executable: git,
        root: root,
        arguments: ["diff", "--cached", "--no-ext-diff", "--no-color"]
      )
      try root.validateCurrentIdentity()
      let combined = combine(outputText(diff.output), outputText(cached.output))
      let stats = diffStatistics(combined)
      return ProjectChangesResult(
        changedFiles: changedFiles,
        diff: combined,
        additions: stats.additions,
        deletions: stats.deletions,
        truncated: diff.output.truncated || cached.output.truncated,
        notGitRepository: notGitRepository
      )
    }

    private func runGit(
      executable: String,
      root: RegisteredRoot,
      arguments: [String]
    ) async throws -> DirectGitResult {
      try root.validateCurrentIdentity()
      return try await DirectGitRunner(defaultTimeout: .seconds(10)).run(
        argv: [executable] + arguments,
        workingDirectory: root.canonicalPath,
        environment: ["LANG": "C", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0"]
      )
    }

    private func parseStatus(_ result: DirectGitResult) -> [String] {
      guard result.exitCode == 0, !result.output.truncated else { return [] }
      return outputText(result.output)
        .split(separator: "\0", omittingEmptySubsequences: true)
        .map(String.init)
    }

    private func outputText(_ output: DirectCommandOutputBuffer) -> String {
      guard output.truncated else { return output.tail }
      return output.head + "\n" + output.tail
    }

    private func combine(_ first: String, _ second: String) -> String {
      guard !second.isEmpty else { return first }
      guard !first.isEmpty else { return second }
      return first + "\n" + second
    }

    private func diffStatistics(_ text: String) -> (additions: Int, deletions: Int) {
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
  }
#endif
