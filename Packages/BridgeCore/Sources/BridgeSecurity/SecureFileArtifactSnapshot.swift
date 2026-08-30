import Foundation

public enum SecureFileArtifactError: Error, Equatable, Sendable {
  case invalidPath
  case invalidMaximumBytes
  case openFailed
  case metadataUnavailable
  case notRegularFile
  case unsafePermissions
  case executableRequired
  case invalidSnapshot
  case fileTooLarge
  case readFailed
  case changed
  case invalidModificationTime
  case invalidDigest
}

/// A bounded identity and digest captured from one trusted regular file.
///
/// `canonicalPath` is Foundation's standardized, symlink-resolved path. The
/// opened handle remains authoritative for type, identity, size, and digest.
public struct SecureFileArtifactSnapshot: Codable, Equatable, Sendable {
  public static let defaultMaximumBytes: UInt64 = 1_073_741_824

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
    try Self.validateAbsolutePath(canonicalPath)
    guard inode > 0,
      fileSize > 0,
      fileSize <= Self.defaultMaximumBytes,
      modificationTimeNanoseconds >= 0
    else {
      throw SecureFileArtifactError.invalidSnapshot
    }
    guard Self.isLowercaseSHA256(sha256) else {
      throw SecureFileArtifactError.invalidDigest
    }
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
    self.sha256 = sha256
  }

  public init(
    capturing path: String,
    requiresExecutable: Bool = false,
    maximumBytes: UInt64 = Self.defaultMaximumBytes
  ) throws {
    self = try Self.captureSnapshot(
      at: path,
      requiresExecutable: requiresExecutable,
      maximumBytes: maximumBytes
    )
  }

  public static func capture(
    at path: String,
    requiresExecutable: Bool = false,
    maximumBytes: UInt64 = Self.defaultMaximumBytes
  ) throws -> Self {
    try Self(capturing: path, requiresExecutable: requiresExecutable, maximumBytes: maximumBytes)
  }

  static func validateCaptureLimit(_ maximumBytes: UInt64) throws {
    guard maximumBytes > 0,
      maximumBytes <= Self.defaultMaximumBytes,
      maximumBytes <= UInt64(Int.max)
    else {
      throw SecureFileArtifactError.invalidMaximumBytes
    }
  }

  fileprivate static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}
