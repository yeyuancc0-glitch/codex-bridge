import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct DeepSeekHarnessACPFileSnapshot: Sendable {
  let path: String
  let device: UInt64
  let inode: UInt64
  let fileSize: UInt64
  let modificationTimeNanoseconds: Int64
  let sha256: String

  init(capturing path: String, requiresExecutable: Bool) throws {
    self.path = path
    guard path.hasPrefix("/"), !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("path")
    }
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid() || metadata.st_uid == 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0,
      metadata.st_size > 0,
      UInt64(metadata.st_size) <= 1_073_741_824
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("identity")
    }
    if requiresExecutable {
      let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
      guard metadata.st_mode & executableBits != 0 else {
        throw DeepSeekHarnessACPError.artifactInvalid("executable")
      }
    }
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw DeepSeekHarnessACPError.artifactInvalid("open")
    }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
      throw DeepSeekHarnessACPError.artifactInvalid("identity")
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw DeepSeekHarnessACPError.artifactInvalid("digest")
      }
      hasher.update(data: Data(buffer.prefix(count)))
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("changed")
    }
    let seconds = Int64(after.st_mtimespec.tv_sec)
    let nanoseconds = Int64(after.st_mtimespec.tv_nsec)
    let (multiplied, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let (modification, addOverflow) = multiplied.addingReportingOverflow(nanoseconds)
    guard seconds >= 0, (0..<1_000_000_000).contains(nanoseconds),
      !multiplyOverflow, !addOverflow
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("mtime")
    }
    self.device = UInt64(after.st_dev)
    self.inode = UInt64(after.st_ino)
    self.fileSize = UInt64(after.st_size)
    self.modificationTimeNanoseconds = modification
    self.sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
