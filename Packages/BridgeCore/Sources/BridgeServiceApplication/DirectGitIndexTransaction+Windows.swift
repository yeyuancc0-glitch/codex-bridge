#if canImport(WinSDK)
  import BridgeDirectCommand
  import Foundation
  import WinSDK

  final class DirectGitIndexTransaction: @unchecked Sendable {
    private enum Constants {
      static let genericRead = DWORD(0x8000_0000)
      static let genericWrite = DWORD(0x4000_0000)
      static let shareRead = DWORD(0x0000_0001)
      static let openReparsePoint = DWORD(0x0020_0000)
      static let writeThrough = DWORD(0x8000_0000)
      static let normalAttributes = DWORD(0x0000_0080)
      static let moveReplaceExisting = DWORD(0x0000_0001)
      static let moveWriteThrough = DWORD(0x0000_0008)
    }

    private let indexURL: URL
    private let lockURL: URL
    private let snapshotURL: URL
    private let stateLock = NSLock()
    private var lockHandle: HANDLE?

    private init(indexURL: URL, lockURL: URL, snapshotURL: URL, lockHandle: HANDLE) {
      self.indexURL = indexURL
      self.lockURL = lockURL
      self.snapshotURL = snapshotURL
      self.lockHandle = lockHandle
    }

    static func begin(
      root: String,
      git: String,
      runner: DirectGitRunner
    ) async throws -> DirectGitIndexTransaction {
      let indexURL = try await indexURL(root: root, git: git, runner: runner)
      let lockURL = URL(fileURLWithPath: indexURL.path + ".lock")
      let snapshotURL = indexURL.deletingLastPathComponent().appendingPathComponent(
        ".codex-bridge-index-\(Foundation.UUID().uuidString)"
      )
      let lockHandle = try createExclusiveFile(at: lockURL)
      let transaction = DirectGitIndexTransaction(
        indexURL: indexURL,
        lockURL: lockURL,
        snapshotURL: snapshotURL,
        lockHandle: lockHandle
      )
      do {
        if FileManager.default.fileExists(atPath: indexURL.path) {
          try copyRegularFile(from: indexURL, to: snapshotURL)
        } else {
          let initialized = try await runner.run(
            argv: [git, "-C", root, "read-tree", "--empty"],
            workingDirectory: root,
            environment: ["GIT_INDEX_FILE": snapshotURL.path]
          )
          guard initialized.exitCode == 0 else {
            throw DirectGitCommitError.gitFailed(
              "The Git index snapshot could not be initialized."
            )
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
      let handle = takeLockHandle()
      if let handle { CloseHandle(handle) }
      Self.deleteFile(at: lockURL)
      Self.deleteFile(at: snapshotURL)
    }

    private func installSnapshot() throws {
      let source = try Self.openRegularFileForReading(at: snapshotURL)
      defer { CloseHandle(source) }
      guard let destination = takeLockHandle() else {
        throw DirectGitCommitError.gitFailed(
          "The commit was created, but the real Git index lock was lost."
        )
      }

      SetLastError(DWORD(ERROR_SUCCESS))
      let position = SetFilePointer(destination, 0, nil, DWORD(FILE_BEGIN))
      guard position != DWORD.max || GetLastError() == DWORD(ERROR_SUCCESS),
        SetEndOfFile(destination),
        Self.copyBytes(from: source, to: destination),
        FlushFileBuffers(destination)
      else {
        CloseHandle(destination)
        Self.deleteFile(at: lockURL)
        throw DirectGitCommitError.gitFailed(
          "The commit was created, but the real Git index could not be written."
        )
      }
      CloseHandle(destination)

      let moved = Self.withWidePaths(lockURL.path, indexURL.path) { lock, index in
        MoveFileExW(
          lock,
          index,
          Constants.moveReplaceExisting | Constants.moveWriteThrough
        )
      }
      guard moved else {
        Self.deleteFile(at: lockURL)
        throw DirectGitCommitError.gitFailed(
          "The commit was created, but the real Git index could not be installed."
        )
      }
      Self.deleteFile(at: snapshotURL)
    }

    private func takeLockHandle() -> HANDLE? {
      stateLock.lock()
      defer { stateLock.unlock() }
      let current = lockHandle
      lockHandle = nil
      return current
    }

    private static func indexURL(
      root: String,
      git: String,
      runner: DirectGitRunner
    ) async throws -> URL {
      let result = try await runner.run(
        argv: [git, "-C", root, "rev-parse", "--git-path", "index"],
        workingDirectory: root
      )
      guard result.exitCode == 0,
        let rawPath = result.output.tail.split(separator: "\n").first
      else {
        throw DirectGitCommitError.gitFailed("Git did not return the repository index path.")
      }
      let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("\\\\") else {
        throw DirectGitCommitError.gitFailed("Git returned an invalid repository index path.")
      }
      return URL(
        fileURLWithPath: path,
        relativeTo: URL(fileURLWithPath: root, isDirectory: true)
      ).standardizedFileURL
    }

    private static func createExclusiveFile(at url: URL) throws -> HANDLE {
      let handle = withWidePath(url.path) { path in
        CreateFileW(
          path,
          Constants.genericWrite,
          0,
          nil,
          DWORD(CREATE_NEW),
          Constants.normalAttributes | Constants.openReparsePoint | Constants.writeThrough,
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        let code = GetLastError()
        throw DirectGitCommitError.gitFailed(
          code == DWORD(ERROR_FILE_EXISTS) || code == DWORD(ERROR_ALREADY_EXISTS)
            ? "The Git index is busy; no commit was created."
            : "The Git index could not be locked; no commit was created."
        )
      }
      return handle
    }

    private static func copyRegularFile(from sourceURL: URL, to destinationURL: URL) throws {
      let source = try openRegularFileForReading(at: sourceURL)
      defer { CloseHandle(source) }
      let destination = try createExclusiveFile(at: destinationURL)
      let copied = copyBytes(from: source, to: destination) && FlushFileBuffers(destination)
      CloseHandle(destination)
      guard copied else {
        deleteFile(at: destinationURL)
        throw DirectGitCommitError.gitFailed("The Git index snapshot could not be copied.")
      }
    }

    private static func openRegularFileForReading(at url: URL) throws -> HANDLE {
      let handle = withWidePath(url.path) { path in
        CreateFileW(
          path,
          Constants.genericRead,
          Constants.shareRead,
          nil,
          DWORD(OPEN_EXISTING),
          Constants.normalAttributes | Constants.openReparsePoint,
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw DirectGitCommitError.gitFailed("The Git index snapshot could not be opened.")
      }
      var attributes = FILE_ATTRIBUTE_TAG_INFO()
      guard
        GetFileInformationByHandleEx(
          handle,
          FileAttributeTagInfo,
          &attributes,
          DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)
        ),
        attributes.FileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        attributes.FileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        GetFileType(handle) == DWORD(FILE_TYPE_DISK)
      else {
        CloseHandle(handle)
        throw DirectGitCommitError.gitFailed("The Git index is not a regular local file.")
      }
      return handle
    }

    private static func copyBytes(from source: HANDLE, to destination: HANDLE) -> Bool {
      let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1_024, alignment: 16)
      defer { buffer.deallocate() }
      while true {
        var readCount = DWORD(0)
        guard ReadFile(source, buffer.baseAddress, DWORD(buffer.count), &readCount, nil) else {
          return false
        }
        if readCount == 0 { return true }
        var offset = 0
        while offset < Int(readCount) {
          var written = DWORD(0)
          guard
            WriteFile(
              destination,
              buffer.baseAddress!.advanced(by: offset),
              readCount - DWORD(offset),
              &written,
              nil
            ),
            written > 0
          else { return false }
          offset += Int(written)
        }
      }
    }

    private static func deleteFile(at url: URL) {
      _ = withWidePath(url.path) { DeleteFileW($0) }
    }

    private static func withWidePath<Result>(
      _ path: String,
      _ body: (UnsafePointer<WCHAR>) -> Result
    ) -> Result {
      var units = Array(path.utf16)
      units.append(0)
      return units.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    private static func withWidePaths<Result>(
      _ first: String,
      _ second: String,
      _ body: (UnsafePointer<WCHAR>, UnsafePointer<WCHAR>) -> Result
    ) -> Result {
      withWidePath(first) { firstPath in
        withWidePath(second) { secondPath in body(firstPath, secondPath) }
      }
    }
  }
#endif
