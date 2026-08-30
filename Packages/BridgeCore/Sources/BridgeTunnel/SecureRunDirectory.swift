import Foundation

#if canImport(Darwin)
  import Darwin
#endif

#if !os(Windows)
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

    package func readRegularFile(name: String, maximumBytes: Int) throws -> Data {
      guard Self.isSafeName(name), maximumBytes > 0, matchesPath() else {
        throw TunnelHealthError.invalidURLFile
      }
      let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard file >= 0 else { throw TunnelHealthError.unavailable }
      defer { Darwin.close(file) }

      var metadata = stat()
      guard
        fstat(file, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_uid == geteuid(),
        metadata.st_nlink == 1,
        metadata.st_mode & 0o077 == 0,
        metadata.st_size > 0,
        metadata.st_size <= maximumBytes
      else {
        throw TunnelHealthError.invalidURLFile
      }

      var result = Data()
      var buffer = [UInt8](repeating: 0, count: min(1_024, maximumBytes))
      while result.count <= maximumBytes {
        let count = Darwin.read(file, &buffer, buffer.count)
        if count == 0 { break }
        guard count > 0 else { throw TunnelHealthError.unavailable }
        result.append(buffer, count: count)
      }
      guard result.count <= maximumBytes else {
        throw TunnelHealthError.invalidURLFile
      }
      return result
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

#else
  // The pinned tunnel helper has no Windows build; the fd-based secure run
  // directory is only reachable through the POSIX implementation above.
  package final class TunnelDirectoryHandle: @unchecked Sendable {
    package let path: String

    package init(existingRoot: URL) throws {
      throw TunnelManagerError.launchFailed
    }

    package init(creating name: String, in parent: TunnelDirectoryHandle) throws {
      throw TunnelManagerError.launchFailed
    }

    package func matchesPath() -> Bool { false }
    package func contains(name: String, directory: TunnelDirectoryHandle) -> Bool { false }
    package func createDirectory(name: String) throws {
      throw TunnelManagerError.launchFailed
    }
    package func readRegularFile(name: String, maximumBytes: Int) throws -> Data {
      throw TunnelHealthError.invalidURLFile
    }
    package func removeEntry(name: String, directory: Bool = false) throws {
      throw TunnelManagerError.cleanupFailed
    }
  }
#endif
