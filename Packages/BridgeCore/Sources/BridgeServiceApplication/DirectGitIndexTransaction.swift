import BridgeDirectCommand
import Darwin
import Foundation

final class DirectGitIndexTransaction: @unchecked Sendable {
  private let indexURL: URL
  private let lockURL: URL
  private let snapshotURL: URL
  private var lockDescriptor: Int32

  private init(indexURL: URL, lockURL: URL, snapshotURL: URL, lockDescriptor: Int32) {
    self.indexURL = indexURL
    self.lockURL = lockURL
    self.snapshotURL = snapshotURL
    self.lockDescriptor = lockDescriptor
  }

  static func begin(
    root: String,
    git: String,
    runner: DirectGitRunner
  ) async throws -> DirectGitIndexTransaction {
    let pathResult = try await runner.run(
      argv: [git, "-C", root, "rev-parse", "--git-path", "index"],
      workingDirectory: root
    )
    guard pathResult.exitCode == 0,
      let rawPath = pathResult.output.tail.split(separator: "\n").first
    else {
      throw DirectGitCommitError.gitFailed("Git did not return the repository index path.")
    }

    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, !path.contains("\0") else {
      throw DirectGitCommitError.gitFailed("Git returned an invalid repository index path.")
    }
    let indexURL = URL(
      fileURLWithPath: path,
      relativeTo: URL(fileURLWithPath: root, isDirectory: true)
    ).standardizedFileURL
    let lockURL = URL(fileURLWithPath: indexURL.path + ".lock")
    let snapshotURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-bridge-real-git-index-\(UUID().uuidString)")
    let descriptor = open(
      lockURL.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw DirectGitCommitError.gitFailed(
        errno == EEXIST
          ? "The Git index is busy; no commit was created."
          : "The Git index could not be locked; no commit was created."
      )
    }

    let transaction = DirectGitIndexTransaction(
      indexURL: indexURL,
      lockURL: lockURL,
      snapshotURL: snapshotURL,
      lockDescriptor: descriptor
    )
    do {
      if FileManager.default.fileExists(atPath: indexURL.path) {
        try FileManager.default.copyItem(at: indexURL, to: snapshotURL)
      } else {
        let initialized = try await runner.run(
          argv: [git, "-C", root, "read-tree", "--empty"],
          workingDirectory: root,
          environment: ["GIT_INDEX_FILE": snapshotURL.path]
        )
        guard initialized.exitCode == 0 else {
          throw DirectGitCommitError.gitFailed("The Git index snapshot could not be initialized.")
        }
      }
      return transaction
    } catch {
      transaction.cancel()
      throw error
    }
  }

  func synchronize(
    root: String,
    git: String,
    changedFiles: [String],
    runner: DirectGitRunner
  ) async throws {
    let synchronized = try await runner.run(
      argv: [git, "-C", root, "reset", "--quiet", "HEAD", "--"] + changedFiles,
      workingDirectory: root,
      environment: ["GIT_INDEX_FILE": snapshotURL.path]
    )
    guard synchronized.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(
        "The commit was created, but the real Git index snapshot could not be synchronized."
      )
    }
    try installSnapshot()
  }

  func cancel() {
    if lockDescriptor >= 0 {
      _ = close(lockDescriptor)
      lockDescriptor = -1
    }
    _ = unlink(lockURL.path)
    try? FileManager.default.removeItem(at: snapshotURL)
  }

  private func installSnapshot() throws {
    guard lockDescriptor >= 0 else {
      throw DirectGitCommitError.gitFailed(
        "The commit was created, but the real Git index lock was lost."
      )
    }
    let source = open(snapshotURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard source >= 0 else {
      throw DirectGitCommitError.gitFailed(
        "The commit was created, but the real Git index snapshot could not be opened."
      )
    }
    defer { _ = close(source) }

    guard ftruncate(lockDescriptor, 0) == 0, lseek(lockDescriptor, 0, SEEK_SET) == 0,
      copyBytes(from: source, to: lockDescriptor), fchmod(lockDescriptor, S_IRUSR | S_IWUSR) == 0,
      fsync(lockDescriptor) == 0
    else {
      throw DirectGitCommitError.gitFailed(
        "The commit was created, but the real Git index could not be written."
      )
    }

    _ = close(lockDescriptor)
    lockDescriptor = -1
    guard rename(lockURL.path, indexURL.path) == 0 else {
      throw DirectGitCommitError.gitFailed(
        "The commit was created, but the real Git index could not be installed."
      )
    }
    try? FileManager.default.removeItem(at: snapshotURL)
  }

  private func copyBytes(from source: Int32, to destination: Int32) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      var count: Int
      repeat {
        count = read(source, &buffer, buffer.count)
      } while count < 0 && errno == EINTR
      if count == 0 { return true }
      guard count > 0 else { return false }
      var offset = 0
      while offset < count {
        let written = buffer.withUnsafeBytes { bytes in
          write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
        }
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return false }
        offset += written
      }
    }
  }
}
