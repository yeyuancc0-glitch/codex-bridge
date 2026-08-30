#if canImport(Darwin)
  import Crypto
  import Darwin
  import Foundation

  extension SecureFileArtifactSnapshot {
    static func validateAbsolutePath(_ path: String) throws {
      guard path.hasPrefix("/"), validPathText(path) else {
        throw SecureFileArtifactError.invalidPath
      }
    }

    static func captureSnapshot(
      at path: String,
      requiresExecutable: Bool,
      maximumBytes: UInt64
    ) throws -> Self {
      try validateCaptureLimit(maximumBytes)
      let canonicalPath = URL(fileURLWithPath: path)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
      try validateAbsolutePath(canonicalPath)
      let descriptor = Darwin.open(canonicalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard descriptor >= 0 else { throw SecureFileArtifactError.openFailed }
      defer { Darwin.close(descriptor) }

      var before = stat()
      guard fstat(descriptor, &before) == 0 else {
        throw SecureFileArtifactError.metadataUnavailable
      }
      try validate(before, requiresExecutable: requiresExecutable, maximumBytes: maximumBytes)
      let digest = try digest(descriptor, maximumBytes: maximumBytes)

      var after = stat()
      guard fstat(descriptor, &after) == 0 else {
        throw SecureFileArtifactError.metadataUnavailable
      }
      guard sameSnapshot(before, after) else {
        throw SecureFileArtifactError.changed
      }
      let modificationTime = try modificationTimeNanoseconds(after)
      return try Self(
        canonicalPath: canonicalPath,
        device: UInt64(after.st_dev),
        inode: UInt64(after.st_ino),
        fileSize: UInt64(after.st_size),
        modificationTimeNanoseconds: modificationTime,
        sha256: digest
      )
    }

    private static func validPathText(_ path: String) -> Bool {
      path.utf8.count <= 16 * 1_024
        && !path.contains("\0")
        && path.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func validate(
      _ metadata: stat,
      requiresExecutable: Bool,
      maximumBytes: UInt64
    ) throws {
      let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
      let isRegularFile = metadata.st_mode & S_IFMT == S_IFREG
      guard isRegularFile else { throw SecureFileArtifactError.notRegularFile }
      guard metadata.st_uid == getuid() || metadata.st_uid == 0,
        metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
        metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0
      else {
        throw SecureFileArtifactError.unsafePermissions
      }
      guard !requiresExecutable || metadata.st_mode & executableBits != 0 else {
        throw SecureFileArtifactError.executableRequired
      }
      guard metadata.st_size > 0 else { throw SecureFileArtifactError.metadataUnavailable }
      guard UInt64(metadata.st_size) <= maximumBytes else {
        throw SecureFileArtifactError.fileTooLarge
      }
    }

    private static func digest(_ descriptor: Int32, maximumBytes: UInt64) throws -> String {
      var hasher = SHA256()
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      var bytesRead: UInt64 = 0
      while bytesRead < maximumBytes {
        let requested = Int(min(UInt64(buffer.count), maximumBytes - bytesRead))
        let count = buffer.withUnsafeMutableBytes { bytes in
          Darwin.read(descriptor, bytes.baseAddress, requested)
        }
        if count == 0 { break }
        if count < 0 {
          if errno == EINTR { continue }
          throw SecureFileArtifactError.readFailed
        }
        bytesRead += UInt64(count)
        hasher.update(data: Data(buffer.prefix(count)))
      }
      guard bytesRead <= maximumBytes else { throw SecureFileArtifactError.fileTooLarge }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameSnapshot(_ first: stat, _ second: stat) -> Bool {
      first.st_dev == second.st_dev
        && first.st_ino == second.st_ino
        && first.st_size == second.st_size
        && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
        && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
    }

    private static func modificationTimeNanoseconds(_ metadata: stat) throws -> Int64 {
      let seconds = Int64(metadata.st_mtimespec.tv_sec)
      let nanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
      guard seconds >= 0, (0..<1_000_000_000).contains(nanoseconds) else {
        throw SecureFileArtifactError.invalidModificationTime
      }
      let (base, multipliedOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
      let (result, addedOverflow) = base.addingReportingOverflow(nanoseconds)
      guard !multipliedOverflow, !addedOverflow else {
        throw SecureFileArtifactError.invalidModificationTime
      }
      return result
    }
  }
#endif
