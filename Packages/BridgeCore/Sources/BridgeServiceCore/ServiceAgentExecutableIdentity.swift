import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

public struct ServiceAgentExecutableIdentity: Codable, Equatable, Sendable {
  public static let maximumExecutableBytes: UInt64 = 1_073_741_824

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
      fileSize <= Self.maximumExecutableBytes,
      modificationTimeNanoseconds >= 0,
      Self.isLowercaseSHA256(sha256)
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
    }
    #else
    guard canonicalPath.hasPrefix("/"),
      canonicalPath.utf8.count <= 16 * 1_024,
      !canonicalPath.contains("\0"),
      canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil,
      inode > 0,
      fileSize > 0,
      fileSize <= Self.maximumExecutableBytes,
      modificationTimeNanoseconds >= 0,
      Self.isLowercaseSHA256(sha256)
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
    }
    #endif
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
    self.sha256 = sha256
  }

  public init(capturing executablePath: String) throws {
    #if os(Windows)
    // Windows paths carry drive letters instead of a leading slash.
    guard executablePath.utf8.count <= 16 * 1_024,
      !executablePath.contains("\0"),
      executablePath.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executablePath")
    }
    #else
    guard executablePath.hasPrefix("/"),
      executablePath.utf8.count <= 16 * 1_024,
      !executablePath.contains("\0"),
      executablePath.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executablePath")
    }
    #endif
    let canonicalPath = URL(fileURLWithPath: executablePath)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    #if os(Windows)
    guard let handle = ServiceAgentArtifactInspection.open(canonicalPath) else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executablePath")
    }
    defer { CloseHandle(handle) }

    guard let before = ServiceAgentArtifactInspection.snapshot(handle) else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
    }
    try ServiceAgentArtifactInspection.validateExecutable(before, errorField: "agentInstallation.executableIdentity")
    let digest = try ServiceAgentArtifactInspection.digest(
      handle,
      errorField: "agentInstallation.executableIdentity"
    )

    guard let after = ServiceAgentArtifactInspection.snapshot(handle), before == after else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableChanged")
    }
    let modificationTime = try ServiceAgentArtifactInspection.modificationTimeNanoseconds(
      after.lastWriteFileTime,
      errorField: "agentInstallation.executableIdentity"
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
      throw ServiceStoreError.invalidArgument("agentInstallation.executablePath")
    }
    defer { Darwin.close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
    }
    try Self.validateExecutable(before)
    let digest = try Self.digest(descriptor)

    var after = stat()
    guard fstat(descriptor, &after) == 0,
      Self.sameFileSnapshot(before, after)
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableChanged")
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

  #if canImport(Darwin)
    private static func validateExecutable(_ metadata: stat) throws {
      let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
      guard metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_uid == getuid() || metadata.st_uid == 0,
        metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
        metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0,
        metadata.st_mode & executableBits != 0,
        metadata.st_size > 0,
        UInt64(metadata.st_size) <= maximumExecutableBytes
      else {
        throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
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
          throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
        }
        hasher.update(data: Data(buffer.prefix(count)))
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameFileSnapshot(_ first: stat, _ second: stat) -> Bool {
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
        throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
      }
      let (base, multipliedOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
      let (result, addedOverflow) = base.addingReportingOverflow(nanoseconds)
      guard !multipliedOverflow, !addedOverflow else {
        throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
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

#if os(Windows)
  extension ServiceAgentArtifactInspection {
    static func validateExecutable(_ snapshot: Snapshot, errorField: String) throws {
      let isRegularFile =
        snapshot.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        && snapshot.attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      // Windows uses ACLs; the executable bit check applies to POSIX only.
      guard isRegularFile,
        snapshot.inode > 0,
        snapshot.size > 0,
        snapshot.size <= ServiceAgentExecutableIdentity.maximumExecutableBytes
      else {
        throw ServiceStoreError.invalidArgument(errorField)
      }
    }
  }
#endif
