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

    let status = try await runGit(
      workingDirectory: workingDirectory,
      arguments: ["status", "--porcelain=v1", "-z"]
    )
    let notGitRepository = isGitRepositoryFailure(status)
    let changedFiles = parseStatus(status)
    let diff = try await runGit(
      workingDirectory: workingDirectory,
      arguments: ["diff", "--no-ext-diff", "--no-color"]
    )
    let cached = try await runGit(
      workingDirectory: workingDirectory,
      arguments: ["diff", "--cached", "--no-ext-diff", "--no-color"]
    )
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
    workingDirectory: OpenedWorkingDirectory,
    arguments: [String]
  ) async throws -> BoundedProcessResult {
    try workingDirectory.validatePathIdentity()
    let runner = BoundedProcessRunner()
    return try await runner.run(
      BoundedProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: ["LANG=C", "LC_ALL=C", "GIT_OPTIONAL_LOCKS=0"],
        timeout: .seconds(10),
        terminationGracePeriod: .seconds(1),
        maximumStandardOutputBytes: 200 * 1_024,
        maximumStandardErrorBytes: 64 * 1_024
      )
    )
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
