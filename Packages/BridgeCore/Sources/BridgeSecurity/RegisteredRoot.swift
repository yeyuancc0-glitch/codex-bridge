import Darwin
import Foundation

/// Cross-platform filesystem identity. macOS/POSIX roots use decimal
/// st_dev/st_ino encodings; Windows roots use FILE_ID_INFO volume serial and
/// 128-bit file id encodings. The business layer never sees raw device or
/// inode numbers.
public struct FileSystemIdentity: Codable, Equatable, Hashable, Sendable {
  public static let posixKind = "posix-v1"
  public static let windowsFileID128Kind = "windows-fileid128-v1"

  private static let hexLowercaseDigits: Set<Character> = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "a", "b", "c", "d", "e", "f",
  ]

  public let kind: String
  public let volumeID: String
  public let fileID: String

  public init(kind: String, volumeID: String, fileID: String) throws {
    guard volumeID.utf8.count >= 1, volumeID.utf8.count <= 20,
      Self.isDecimal(volumeID)
    else {
      throw PathSecurityError.invalidIdentity
    }
    switch kind {
    case Self.posixKind:
      guard fileID.utf8.count >= 1, fileID.utf8.count <= 20, Self.isDecimal(fileID) else {
        throw PathSecurityError.invalidIdentity
      }
    case Self.windowsFileID128Kind:
      guard fileID.utf8.count == 32,
        fileID.allSatisfy({ Self.hexLowercaseDigits.contains($0) })
      else {
        throw PathSecurityError.invalidIdentity
      }
    default:
      throw PathSecurityError.invalidIdentity
    }
    self.kind = kind
    self.volumeID = volumeID
    self.fileID = fileID
  }

  public init(posixDevice: UInt64, posixInode: UInt64) {
    self.kind = Self.posixKind
    self.volumeID = String(posixDevice)
    self.fileID = String(posixInode)
  }

  /// Numeric POSIX decoding for macOS-only sinks that must keep their exact
  /// historical value encoding (approval evidence digests, legacy records).
  public var posixDeviceValue: UInt64? {
    kind == Self.posixKind ? UInt64(volumeID) : nil
  }

  public var posixInodeValue: UInt64? {
    kind == Self.posixKind ? UInt64(fileID) : nil
  }

  private static func isDecimal(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy(\.isNumber) && value.allSatisfy { $0.isASCII }
  }
}

public struct RegisteredRoot: Codable, Equatable, Sendable {
  public let canonicalPath: String
  public let identity: FileSystemIdentity

  public init(capturing url: URL) throws {
    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw PathSecurityError.rootUnavailable
    }

    canonicalPath = canonical.path
    identity = try Self.readIdentity(atPath: canonical.path)
  }

  public func validateCurrentIdentity() throws {
    guard FileManager.default.fileExists(atPath: canonicalPath) else {
      throw PathSecurityError.rootUnavailable
    }
    guard try Self.readIdentity(atPath: canonicalPath) == identity else {
      throw PathSecurityError.rootIdentityChanged
    }
  }

  static func readIdentity(atPath path: String) throws -> FileSystemIdentity {
    var metadata = stat()
    let status = path.withCString { Darwin.lstat($0, &metadata) }
    guard status == 0 else { throw PathSecurityError.readFailed(errno) }
    return FileSystemIdentity(
      posixDevice: UInt64(metadata.st_dev),
      posixInode: UInt64(metadata.st_ino)
    )
  }
}
