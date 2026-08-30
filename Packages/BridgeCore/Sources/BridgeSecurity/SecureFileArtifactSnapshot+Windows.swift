#if os(Windows)
  import Crypto
  import Foundation
  import WinSDK

  extension SecureFileArtifactSnapshot {
    static func validateAbsolutePath(_ path: String) throws {
      let normalized = path.replacingOccurrences(of: "/", with: "\\")
      guard validPathText(normalized), isAbsoluteWindowsPath(normalized) else {
        throw SecureFileArtifactError.invalidPath
      }
    }

    static func captureSnapshot(
      at path: String,
      requiresExecutable: Bool,
      maximumBytes: UInt64
    ) throws -> Self {
      try validateCaptureLimit(maximumBytes)
      let canonicalPath = try canonicalPath(for: path)
      let handle = canonicalPath.withCString(encodedAs: UTF16.self) { wide in
        CreateFileW(
          wide,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw SecureFileArtifactError.openFailed
      }
      defer { _ = CloseHandle(handle) }

      guard let before = metadata(of: handle) else {
        throw SecureFileArtifactError.metadataUnavailable
      }
      try validate(before, requiresExecutable: requiresExecutable, maximumBytes: maximumBytes)
      let digest = try digest(handle, maximumBytes: maximumBytes)
      guard let after = metadata(of: handle) else {
        throw SecureFileArtifactError.metadataUnavailable
      }
      guard before == after else { throw SecureFileArtifactError.changed }
      let modificationTime = try modificationTimeNanoseconds(after.lastWriteFileTime)
      return try Self(
        canonicalPath: canonicalPath,
        device: after.device,
        inode: after.inode,
        fileSize: after.size,
        modificationTimeNanoseconds: modificationTime,
        sha256: digest
      )
    }

    private struct Metadata: Equatable {
      let device: UInt64
      let inode: UInt64
      let size: UInt64
      let lastWriteFileTime: UInt64
      let attributes: DWORD
    }

    private static func validPathText(_ path: String) -> Bool {
      path.utf8.count <= 16 * 1_024
        && !path.contains("\0")
        && path.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func canonicalPath(for path: String) throws -> String {
      let standardized = URL(fileURLWithPath: path)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
      var normalized = standardized.replacingOccurrences(of: "/", with: "\\")
      if isFoundationDrivePath(normalized) {
        normalized.removeFirst()
      }
      guard validPathText(normalized), isAbsoluteWindowsPath(normalized) else {
        throw SecureFileArtifactError.invalidPath
      }
      return normalized
    }

    private static func isFoundationDrivePath(_ path: String) -> Bool {
      guard path.count >= 3 else { return false }
      let characters = Array(path.prefix(3))
      return characters[0] == "\\"
        && isASCII(letter: characters[1])
        && characters[2] == ":"
    }

    private static func isAbsoluteWindowsPath(_ path: String) -> Bool {
      let lowercased = path.lowercased()
      guard !lowercased.hasPrefix("\\\\?\\"),
        !lowercased.hasPrefix("\\\\.\\"),
        !lowercased.hasPrefix("\\??\\"),
        !lowercased.hasPrefix("\\device\\")
      else {
        return false
      }
      for (offset, character) in path.enumerated() where character == ":" {
        guard offset == 1 else { return false }
      }
      if path.count >= 3 {
        let characters = Array(path.prefix(3))
        if isASCII(letter: characters[0]), characters[1] == ":" {
          return characters[2] == "\\"
        }
      }
      guard path.hasPrefix("\\\\") else { return false }
      let components = path.dropFirst(2).split(separator: "\\")
      return components.count >= 2
    }

    private static func isASCII(letter character: Character) -> Bool {
      guard let scalar = character.unicodeScalars.first, scalar.value <= 127 else { return false }
      return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func metadata(of handle: HANDLE) -> Metadata? {
      var information = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &information) else { return nil }
      let lastWrite = information.ftLastWriteTime
      return Metadata(
        device: UInt64(information.dwVolumeSerialNumber),
        inode: (UInt64(information.nFileIndexHigh) << 32) | UInt64(information.nFileIndexLow),
        size: (UInt64(information.nFileSizeHigh) << 32) | UInt64(information.nFileSizeLow),
        lastWriteFileTime: (UInt64(lastWrite.dwHighDateTime) << 32)
          | UInt64(lastWrite.dwLowDateTime),
        attributes: information.dwFileAttributes
      )
    }

    private static func validate(
      _ metadata: Metadata,
      requiresExecutable: Bool,
      maximumBytes: UInt64
    ) throws {
      // Windows uses ACLs and loader rules; POSIX owner/mode bits do not apply.
      _ = requiresExecutable
      let regular =
        metadata.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        && metadata.attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      guard regular else { throw SecureFileArtifactError.notRegularFile }
      guard metadata.inode > 0 else { throw SecureFileArtifactError.metadataUnavailable }
      guard metadata.size > 0 else { throw SecureFileArtifactError.metadataUnavailable }
      guard metadata.size <= maximumBytes else { throw SecureFileArtifactError.fileTooLarge }
    }

    private static func digest(_ handle: HANDLE, maximumBytes: UInt64) throws -> String {
      var hasher = SHA256()
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      var bytesRead: UInt64 = 0
      while bytesRead < maximumBytes {
        let requested = Int(min(UInt64(buffer.count), maximumBytes - bytesRead))
        var readBytes: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(requested), &readBytes, nil)
        }
        guard succeeded else { throw SecureFileArtifactError.readFailed }
        if readBytes == 0 { break }
        bytesRead += UInt64(readBytes)
        guard bytesRead <= maximumBytes else { throw SecureFileArtifactError.fileTooLarge }
        hasher.update(data: Data(buffer.prefix(Int(readBytes))))
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func modificationTimeNanoseconds(_ fileTime: UInt64) throws -> Int64 {
      let unixEpochFileTime: UInt64 = 116_444_736_000_000_000
      guard fileTime >= unixEpochFileTime else {
        throw SecureFileArtifactError.invalidModificationTime
      }
      let intervals = fileTime - unixEpochFileTime
      guard intervals <= UInt64(Int64.max) / 100 else {
        throw SecureFileArtifactError.invalidModificationTime
      }
      return Int64(intervals * 100)
    }
  }
#endif
