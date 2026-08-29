import BridgeDirectCommand
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif

final class DirectGitIndexTransaction: @unchecked Sendable {
  private let indexURL: URL
  private let lockURL: URL
  private let snapshotURL: URL
  #if os(Windows)
    private var lockHandle: OpaquePointer?

    private init(
      indexURL: URL,
      lockURL: URL,
      snapshotURL: URL,
      lockHandle: OpaquePointer?
    ) {
      self.indexURL = indexURL
      self.lockURL = lockURL
      self.snapshotURL = snapshotURL
      self.lockHandle = lockHandle
    }
  #else
    private var lockDescriptor: Int32

    private init(indexURL: URL, lockURL: URL, snapshotURL: URL, lockDescriptor: Int32) {
      self.indexURL = indexURL
      self.lockURL = lockURL
      self.snapshotURL = snapshotURL
      self.lockDescriptor = lockDescriptor
    }
  #endif

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
    #if os(Windows)
    let lockHandle: OpaquePointer? = lockURL.path.withCString(encodedAs: UTF16.self) {
      CreateFileW(
        $0,
        DWORD(GENERIC_WRITE),
        0,
        nil,
        DWORD(CREATE_NEW),
        DWORD(FILE_ATTRIBUTE_NORMAL),
        nil
      )
    }
    guard let acquiredHandle = lockHandle else {
      throw DirectGitCommitError.gitFailed(
        GetLastError() == DWORD(ERROR_FILE_EXISTS)
          ? "The Git index is busy; no commit was created."
          : "The Git index could not be locked; no commit was created."
      )
    }

    let transaction = DirectGitIndexTransaction(
      indexURL: indexURL,
      lockURL: lockURL,
      snapshotURL: snapshotURL,
      lockHandle: acquiredHandle
    )
    #else
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
    #endif
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
    #if os(Windows)
    if let lockHandle {
      _ = CloseHandle(lockHandle)
      self.lockHandle = nil
    }
    _ = lockURL.path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
    #else
    if lockDescriptor >= 0 {
      _ = close(lockDescriptor)
      lockDescriptor = -1
    }
    _ = unlink(lockURL.path)
    #endif
    try? FileManager.default.removeItem(at: snapshotURL)
  }

  private func installSnapshot() throws {
    #if os(Windows)
    guard let lockHandle else {
      throw DirectGitCommitError.gitFailed(
        "The commit was created, but the real Git index lock was lost."
      )
    }
    guard let source: OpaquePointer = snapshotURL.path.withCString(encodedAs: UTF16.self)({
      CreateFileW(
        $0,
        DWORD(GENERIC_READ),
        DWORD(FILE_SHARE_READ),
        nil,
        DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
        nil
      )
    })
    else {
      throw DirectGitCommitError.gitFailed(
        "The commit was created, but the real Git index snapshot could not be opened."
      )
    }
    defer { CloseHandle(source) }

    // Windows uses ACLs; the POSIX mode reset does not apply.
    guard SetFilePointer(lockHandle, 0, nil, DWORD(FILE_BEGIN)) != INVALID_SET_FILE_POINTER,
      SetEndOfFile(lockHandle) != 0,
      SetFilePointer(lockHandle, 0, nil, DWORD(FILE_BEGIN)) != INVALID_SET_FILE_POINTER,
      copyBytes(from: source, to: lockHandle),
      FlushFileBuffers(lockHandle) != 0
    else {
      throw DirectGitCommitError.gitFailed(
        "The commit was created, but the real Git index could not be written."
      )
    }

    _ = CloseHandle(lockHandle)
    self.lockHandle = nil
    let installed = indexURL.path.withCString(encodedAs: UTF16.self) { indexWide in
      lockURL.path.withCString(encodedAs: UTF16.self) { lockWide in
        MoveFileExW(lockWide, indexWide, DWORD(MOVEFILE_REPLACE_EXISTING))
      }
    }
    guard installed != 0 else {
      throw DirectGitCommitError.gitFailed(
        "The commit was created, but the real Git index could not be installed."
      )
    }
    try? FileManager.default.removeItem(at: snapshotURL)
    #else
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
    #endif
  }

  #if os(Windows)
    private func copyBytes(from source: OpaquePointer, to destination: OpaquePointer) -> Bool {
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while true {
        var received: DWORD = 0
        let readSucceeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(source, bytes.baseAddress, DWORD(bytes.count), &received, nil)
        }
        guard readSucceeded != 0 else { return false }
        if received == 0 { return true }
        var offset = 0
        while offset < Int(received) {
          var written: DWORD = 0
          let writeSucceeded = buffer.withUnsafeBytes { bytes in
            WriteFile(
              destination,
              bytes.baseAddress!.advanced(by: offset),
              received - DWORD(offset),
              &written,
              nil
            )
          }
          guard writeSucceeded != 0, written > 0 else { return false }
          offset += Int(written)
        }
      }
    }
  #else
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
  #endif
}
