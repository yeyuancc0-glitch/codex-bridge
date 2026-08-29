import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

#if os(Windows)
  /// Windows counterpart of the POSIX stat-based inspection shared by the
  /// agent artifact identity types.
  enum ServiceAgentArtifactInspection {
    struct Snapshot: Equatable {
      var device: UInt64
      var inode: UInt64
      var size: UInt64
      var lastWriteFileTime: UInt64
      var attributes: DWORD
    }

    static func open(_ path: String) -> OpaquePointer? {
      path.withCString(encodedAs: UTF16.self) {
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
    }

    static func snapshot(_ handle: OpaquePointer) -> Snapshot? {
      var information = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &information) != 0 else { return nil }
      let lastWrite = information.ftLastWriteTime
      return Snapshot(
        device: UInt64(information.dwVolumeSerialNumber),
        inode: (UInt64(information.nFileIndexHigh) << 32) | UInt64(information.nFileIndexLow),
        size: (UInt64(information.nFileSizeHigh) << 32) | UInt64(information.nFileSizeLow),
        lastWriteFileTime: (UInt64(lastWrite.dwHighDateTime) << 32)
          | UInt64(lastWrite.dwLowDateTime),
        attributes: information.dwFileAttributes
      )
    }

    static func validate(
      _ snapshot: Snapshot,
      requiresExecutable: Bool,
      errorField: String
    ) throws {
      let isRegularFile =
        snapshot.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        && snapshot.attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      // Windows uses ACLs; POSIX owner/permission bit checks do not apply, and
      // executability is decided by the loader rather than a mode bit.
      _ = requiresExecutable
      guard isRegularFile,
        snapshot.inode > 0,
        snapshot.size > 0,
        snapshot.size <= ServiceAgentFileIdentity.maximumFileBytes
      else {
        throw ServiceStoreError.invalidArgument(errorField)
      }
    }

    static func digest(_ handle: OpaquePointer, errorField: String) throws -> String {
      var hasher = SHA256()
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while true {
        var readBytes: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &readBytes, nil)
        }
        guard succeeded != 0 else {
          throw ServiceStoreError.invalidArgument(errorField)
        }
        if readBytes == 0 { break }
        hasher.update(data: Data(buffer.prefix(Int(readBytes))))
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func modificationTimeNanoseconds(
      _ fileTime: UInt64,
      errorField: String
    ) throws -> Int64 {
      // FILETIME counts 100ns intervals since 1601-01-01.
      let unixEpochFileTime: UInt64 = 116_444_736_000_000_000
      guard fileTime >= unixEpochFileTime else {
        throw ServiceStoreError.invalidArgument(errorField)
      }
      let nanoseconds = Int64((fileTime - unixEpochFileTime) * 100)
      guard nanoseconds >= 0 else {
        throw ServiceStoreError.invalidArgument(errorField)
      }
      return nanoseconds
    }
  }
#endif

public struct ServiceAgentFileIdentity: Codable, Equatable, Sendable {
  public static let maximumFileBytes: UInt64 = 1_073_741_824
  public static let maximumConfigurationBytes: UInt64 = 256 * 1_024

  public let canonicalPath: String
  public let device: UInt64
  public let inode: UInt64
  public let fileSize: UInt64
  public let modificationTimeNanoseconds: Int64
  public let sha256: String

  public init(
    canonicalPath: String,
    device: UInt64,
    inode: UInt64,
    fileSize: UInt64,
    modificationTimeNanoseconds: Int64,
    sha256: String
  ) throws {
    #if os(Windows)
    // Windows paths carry drive letters instead of a leading slash.
    guard canonicalPath.utf8.count <= 16 * 1_024,
      !canonicalPath.contains("\0"),
      canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil,
      inode > 0,
      fileSize > 0,
      fileSize <= Self.maximumFileBytes,
      modificationTimeNanoseconds >= 0,
      Self.isLowercaseSHA256(sha256)
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
    #else
    guard canonicalPath.hasPrefix("/"),
      canonicalPath.utf8.count <= 16 * 1_024,
      !canonicalPath.contains("\0"),
      canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil,
      inode > 0,
      fileSize > 0,
      fileSize <= Self.maximumFileBytes,
      modificationTimeNanoseconds >= 0,
      Self.isLowercaseSHA256(sha256)
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
    #endif
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
    self.sha256 = sha256
  }

  public init(capturing path: String, requiresExecutable: Bool = false) throws {
    try Self.validate(path: path)
    let canonicalPath = URL(fileURLWithPath: path)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    #if os(Windows)
    guard let handle = ServiceAgentArtifactInspection.open(canonicalPath) else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactPath")
    }
    defer { CloseHandle(handle) }

    guard let before = ServiceAgentArtifactInspection.snapshot(handle) else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
    try ServiceAgentArtifactInspection.validate(
      before,
      requiresExecutable: requiresExecutable,
      errorField: "agentInstallation.artifactIdentity"
    )
    let digest = try ServiceAgentArtifactInspection.digest(
      handle,
      errorField: "agentInstallation.artifactIdentity"
    )

    guard let after = ServiceAgentArtifactInspection.snapshot(handle), before == after else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactChanged")
    }
    let modificationTime = try ServiceAgentArtifactInspection.modificationTimeNanoseconds(
      after.lastWriteFileTime,
      errorField: "agentInstallation.artifactIdentity"
    )
    try self.init(
      canonicalPath: canonicalPath,
      device: after.device,
      inode: after.inode,
      fileSize: after.size,
      modificationTimeNanoseconds: modificationTime,
      sha256: digest
    )
    #elseif canImport(Darwin)
    let descriptor = Darwin.open(canonicalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactPath")
    }
    defer { Darwin.close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
    try Self.validateFile(before, requiresExecutable: requiresExecutable)
    let digest = try Self.digest(descriptor)

    var after = stat()
    guard fstat(descriptor, &after) == 0, Self.sameSnapshot(before, after) else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactChanged")
    }
    let modificationTime = try Self.modificationTimeNanoseconds(after)
    try self.init(
      canonicalPath: canonicalPath,
      device: UInt64(after.st_dev),
      inode: UInt64(after.st_ino),
      fileSize: UInt64(after.st_size),
      modificationTimeNanoseconds: modificationTime,
      sha256: digest
    )
    #endif
  }

  public init(capturing path: String, role: ServiceAgentInstallationArtifactRole) throws {
    try self.init(capturing: path, requiresExecutable: role.requiresExecutable)
  }

  private static func validate(path: String) throws {
    #if os(Windows)
    // Windows paths carry drive letters instead of a leading slash.
    guard path.utf8.count <= 16 * 1_024,
      !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactPath")
    }
    #else
    guard path.hasPrefix("/"),
      path.utf8.count <= 16 * 1_024,
      !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactPath")
    }
    #endif
  }

  #if canImport(Darwin)
    private static func validateFile(_ metadata: stat, requiresExecutable: Bool) throws {
      let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
      let hasExecutableBit = metadata.st_mode & executableBits != 0
      guard metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_uid == getuid() || metadata.st_uid == 0,
        metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
        metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0,
        !requiresExecutable || hasExecutableBit,
        metadata.st_size > 0,
        UInt64(metadata.st_size) <= Self.maximumFileBytes
      else {
        throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
      }
    }

    private static func digest(_ descriptor: Int32) throws -> String {
      var hasher = SHA256()
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
          Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count == 0 { break }
        if count < 0 {
          if errno == EINTR { continue }
          throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
        }
        hasher.update(data: Data(buffer.prefix(count)))
      }
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
        throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
      }
      let (base, multipliedOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
      let (result, addedOverflow) = base.addingReportingOverflow(nanoseconds)
      guard !multipliedOverflow, !addedOverflow else {
        throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
      }
      return result
    }
  #endif

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}
