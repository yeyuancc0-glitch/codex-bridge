#if canImport(WinSDK)
  import BridgeDirectCommand
  import Foundation

  /// Direct Git commit remains unavailable until its index lock/snapshot
  /// transaction has a handle-relative Windows implementation. Failing at
  /// transaction start prevents a partial commit or an unsafe path fallback.
  final class DirectGitIndexTransaction: @unchecked Sendable {
    static func begin(
      root: String,
      git: String,
      runner: DirectGitRunner
    ) async throws -> DirectGitIndexTransaction {
      _ = (root, git, runner)
      throw DirectGitCommitError.gitFailed(
        "Direct Git commit is unavailable on Windows."
      )
    }

    func synchronize(
      root: String,
      git: String,
      changedFiles: [String],
      runner: DirectGitRunner
    ) async throws {
      _ = (root, git, changedFiles, runner)
      throw DirectGitCommitError.gitFailed(
        "Direct Git commit is unavailable on Windows."
      )
    }

    func cancel() {}
  }
#endif
