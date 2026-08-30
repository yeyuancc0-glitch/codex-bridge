import CryptoKit
import Darwin
import Foundation

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
  }

  public init(capturing path: String, role: ServiceAgentInstallationArtifactRole) throws {
    try self.init(capturing: path, requiresExecutable: role.requiresExecutable)
  }

  private static func validate(path: String) throws {
    guard path.hasPrefix("/"),
      path.utf8.count <= 16 * 1_024,
      !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactPath")
    }
  }

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

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}
