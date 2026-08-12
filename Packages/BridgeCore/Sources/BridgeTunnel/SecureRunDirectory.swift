import Darwin
import Foundation

package final class TunnelDirectoryHandle: @unchecked Sendable {
  package let path: String
  package let descriptor: Int32
  private let device: dev_t
  private let inode: ino_t

  package init(existingRoot: URL) throws {
    path = existingRoot.path
    descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw TunnelManagerError.launchFailed }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      Darwin.close(descriptor)
      throw TunnelManagerError.launchFailed
    }
    guard
      (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o777 == 0o700
    else {
      Darwin.close(descriptor)
      throw TunnelManagerError.launchFailed
    }
    device = metadata.st_dev
    inode = metadata.st_ino
    guard matchesPath() else {
      Darwin.close(descriptor)
      throw TunnelManagerError.launchFailed
    }
  }

  package init(creating name: String, in parent: TunnelDirectoryHandle) throws {
    guard Self.isSafeName(name), parent.matchesPath() else {
      throw TunnelManagerError.launchFailed
    }
    guard mkdirat(parent.descriptor, name, 0o700) == 0 else {
      throw TunnelManagerError.launchFailed
    }
    let opened = openat(
      parent.descriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard opened >= 0 else {
      _ = unlinkat(parent.descriptor, name, AT_REMOVEDIR)
      throw TunnelManagerError.launchFailed
    }
    path = URL(fileURLWithPath: parent.path).appendingPathComponent(name).path
    descriptor = opened
    var metadata = stat()
    guard
      fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o777 == 0o700
    else {
      Darwin.close(descriptor)
      _ = unlinkat(parent.descriptor, name, AT_REMOVEDIR)
      throw TunnelManagerError.launchFailed
    }
    device = metadata.st_dev
    inode = metadata.st_ino
  }

  deinit {
    Darwin.close(descriptor)
  }

  package func matchesPath() -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0
      && (metadata.st_mode & S_IFMT) == S_IFDIR
      && metadata.st_uid == geteuid()
      && metadata.st_mode & 0o777 == 0o700
      && metadata.st_dev == device
      && metadata.st_ino == inode
  }

  package func contains(name: String, directory: TunnelDirectoryHandle) -> Bool {
    guard Self.isSafeName(name), matchesPath(), directory.matchesPath() else { return false }
    var metadata = stat()
    return fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0
      && (metadata.st_mode & S_IFMT) == S_IFDIR
      && metadata.st_dev == directory.device
      && metadata.st_ino == directory.inode
  }

  package func createDirectory(name: String) throws {
    guard Self.isSafeName(name), matchesPath(), mkdirat(descriptor, name, 0o700) == 0 else {
      throw TunnelManagerError.launchFailed
    }
  }

  package func removeEntry(name: String, directory: Bool = false) throws {
    guard Self.isSafeName(name) else { throw TunnelManagerError.cleanupFailed }
    let flags = directory ? AT_REMOVEDIR : 0
    guard unlinkat(descriptor, name, flags) == 0 || errno == ENOENT else {
      throw TunnelManagerError.cleanupFailed
    }
  }

  private static func isSafeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }
}
