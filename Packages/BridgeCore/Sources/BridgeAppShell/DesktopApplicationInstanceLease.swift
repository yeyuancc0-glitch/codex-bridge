import Darwin
import Foundation

@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

enum DesktopApplicationInstanceLeaseError: Error, Equatable {
  case insecureFile
  case alreadyRunning
  case systemFailure(Int32)
}

final class DesktopApplicationInstanceLease: @unchecked Sendable {
  private final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func reserve(_ path: String) -> Bool {
      lock.withLock { paths.insert(path).inserted }
    }

    func release(_ path: String) {
      _ = lock.withLock { paths.remove(path) }
    }
  }

  private static let processRegistry = ProcessRegistry()
  private let lock = NSLock()
  private let path: String
  private var directoryDescriptor: Int32
  private var descriptor: Int32

  init(directoryURL: URL) throws {
    let url = directoryURL.appendingPathComponent("application-instance.lock", isDirectory: false)
    let path = url.standardizedFileURL.path
    guard Self.processRegistry.reserve(path) else {
      throw DesktopApplicationInstanceLeaseError.alreadyRunning
    }
    let directoryDescriptor = open(
      directoryURL.standardizedFileURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0 else {
      Self.processRegistry.release(path)
      if errno == ELOOP { throw DesktopApplicationInstanceLeaseError.insecureFile }
      throw DesktopApplicationInstanceLeaseError.systemFailure(errno)
    }
    let descriptor = openat(
      directoryDescriptor,
      "application-instance.lock",
      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      close(directoryDescriptor)
      Self.processRegistry.release(path)
      if errno == ELOOP { throw DesktopApplicationInstanceLeaseError.insecureFile }
      throw DesktopApplicationInstanceLeaseError.systemFailure(errno)
    }
    do {
      try Self.validateDirectory(directoryDescriptor)
      try Self.acquireDirectory(directoryDescriptor)
      try Self.validateFile(descriptor)
      try Self.acquire(descriptor)
      self.path = path
      self.directoryDescriptor = directoryDescriptor
      self.descriptor = descriptor
    } catch {
      close(descriptor)
      close(directoryDescriptor)
      Self.processRegistry.release(path)
      throw error
    }
  }

  func release() {
    let descriptors = lock.withLock { () -> (Int32, Int32) in
      let current = (self.descriptor, directoryDescriptor)
      self.descriptor = -1
      directoryDescriptor = -1
      return current
    }
    let (descriptor, directoryDescriptor) = descriptors
    guard descriptor >= 0 else { return }
    var record = Darwin.flock()
    record.l_type = Int16(F_UNLCK)
    record.l_whence = Int16(SEEK_SET)
    _ = fcntl(descriptor, F_SETLK, &record)
    Self.processRegistry.release(path)
    close(descriptor)
    if directoryDescriptor >= 0 { close(directoryDescriptor) }
  }

  deinit {
    release()
  }

  private static func validateDirectory(_ descriptor: Int32) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw DesktopApplicationInstanceLeaseError.systemFailure(errno)
    }
    guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o777 == 0o700
    else { throw DesktopApplicationInstanceLeaseError.insecureFile }
  }

  private static func validateFile(_ descriptor: Int32) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw DesktopApplicationInstanceLeaseError.systemFailure(errno)
    }
    guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_mode & 0o777 == 0o600
    else { throw DesktopApplicationInstanceLeaseError.insecureFile }
  }

  private static func acquireDirectory(_ descriptor: Int32) throws {
    guard systemFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK { throw DesktopApplicationInstanceLeaseError.alreadyRunning }
      throw DesktopApplicationInstanceLeaseError.systemFailure(errno)
    }
  }

  private static func acquire(_ descriptor: Int32) throws {
    var record = Darwin.flock()
    record.l_type = Int16(F_WRLCK)
    record.l_whence = Int16(SEEK_SET)
    guard fcntl(descriptor, F_SETLK, &record) == 0 else {
      if errno == EACCES || errno == EAGAIN {
        throw DesktopApplicationInstanceLeaseError.alreadyRunning
      }
      throw DesktopApplicationInstanceLeaseError.systemFailure(errno)
    }
  }
}
