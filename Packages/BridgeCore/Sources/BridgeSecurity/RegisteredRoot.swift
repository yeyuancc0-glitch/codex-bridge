import Darwin
import Foundation

public struct FileSystemIdentity: Codable, Equatable, Hashable, Sendable {
  public let device: UInt64
  public let inode: UInt64

  public init(device: UInt64, inode: UInt64) {
    self.device = device
    self.inode = inode
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
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
  }
}
