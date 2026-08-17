import Darwin
import Foundation

struct LegacySourceFiles {
  static let repositoryName = "application.sqlite"
  static let onboardingName = "onboarding.json"
  static let maximumOnboardingBytes = 32 * 1_024
  static let maximumRepositoryBytes = 256 * 1_024 * 1_024

  let rootURL: URL

  func openDirectory() throws -> LegacyVerifiedSourceDirectory? {
    let path = rootURL.path(percentEncoded: false)
    guard rootURL.isFileURL,
      path.hasPrefix("/"),
      path.utf8.count <= 16_384,
      !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw LegacyImportError.insecureSourceDirectory
    }
    let descriptor = open(
      path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0 else {
      throw LegacyImportError.insecureSourceDirectory
    }

    do {
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0 else {
        throw LegacyImportError.insecureSourceDirectory
      }
      return LegacyVerifiedSourceDirectory(
        rootURL: rootURL,
        descriptor: descriptor,
        metadata: try LegacySourceDirectoryMetadata(validating: metadata)
      )
    } catch {
      close(descriptor)
      throw error
    }
  }
}

final class LegacyVerifiedSourceDirectory {
  private let rootURL: URL
  private let descriptor: Int32
  private let metadata: LegacySourceDirectoryMetadata

  fileprivate init(
    rootURL: URL,
    descriptor: Int32,
    metadata: LegacySourceDirectoryMetadata
  ) {
    self.rootURL = rootURL
    self.descriptor = descriptor
    self.metadata = metadata
  }

  deinit {
    close(descriptor)
  }

  func repositoryFile() throws -> LegacyVerifiedSourceFile? {
    guard
      let file = try file(
        name: LegacySourceFiles.repositoryName,
        maximumBytes: LegacySourceFiles.maximumRepositoryBytes,
        forbiddenSiblingNames: [
          "\(LegacySourceFiles.repositoryName)-journal",
          "\(LegacySourceFiles.repositoryName)-shm",
          "\(LegacySourceFiles.repositoryName)-wal",
        ]
      )
    else {
      return nil
    }
    try file.validateRollbackJournalSQLiteHeader()
    return file
  }

  func onboardingData() throws -> Data? {
    guard
      let file = try file(
        name: LegacySourceFiles.onboardingName,
        maximumBytes: LegacySourceFiles.maximumOnboardingBytes
      )
    else {
      return nil
    }
    return try file.read(maximumBytes: LegacySourceFiles.maximumOnboardingBytes)
  }

  fileprivate func validateUnchanged() throws {
    var heldMetadata = stat()
    guard fstat(descriptor, &heldMetadata) == 0,
      try LegacySourceDirectoryMetadata(validating: heldMetadata) == metadata
    else {
      throw LegacyImportError.insecureSourceDirectory
    }

    let currentDescriptor = open(
      rootURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard currentDescriptor >= 0 else {
      throw LegacyImportError.insecureSourceDirectory
    }
    defer { close(currentDescriptor) }

    var currentMetadata = stat()
    guard fstat(currentDescriptor, &currentMetadata) == 0,
      try LegacySourceDirectoryMetadata(validating: currentMetadata) == metadata
    else {
      throw LegacyImportError.insecureSourceDirectory
    }
  }

  fileprivate func validateEntry(
    name: String,
    expectedMetadata: LegacySourceFileMetadata
  ) throws {
    let currentDescriptor = openat(
      descriptor,
      name,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard currentDescriptor >= 0 else {
      throw LegacyImportError.insecureSourceFile(name)
    }
    defer { close(currentDescriptor) }

    var currentMetadata = stat()
    guard fstat(currentDescriptor, &currentMetadata) == 0,
      try LegacySourceFileMetadata(
        validating: currentMetadata,
        name: name,
        maximumBytes: expectedMetadata.maximumBytes
      ) == expectedMetadata
    else {
      throw LegacyImportError.insecureSourceFile(name)
    }
  }

  fileprivate func validateForbiddenSiblings(_ names: [String]) throws {
    for name in names {
      var siblingMetadata = stat()
      if fstatat(descriptor, name, &siblingMetadata, AT_SYMLINK_NOFOLLOW) == 0 {
        throw LegacyImportError.insecureSourceFile(LegacySourceFiles.repositoryName)
      }
      guard errno == ENOENT else { throw LegacyImportError.readFailed }
    }
  }

  private func file(
    name: String,
    maximumBytes: Int,
    forbiddenSiblingNames: [String] = []
  ) throws -> LegacyVerifiedSourceFile? {
    try validateUnchanged()
    try validateForbiddenSiblings(forbiddenSiblingNames)

    let fileDescriptor = openat(
      descriptor,
      name,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    if fileDescriptor < 0, errno == ENOENT { return nil }
    guard fileDescriptor >= 0 else {
      throw LegacyImportError.insecureSourceFile(name)
    }

    do {
      var fileMetadata = stat()
      guard fstat(fileDescriptor, &fileMetadata) == 0 else {
        throw LegacyImportError.insecureSourceFile(name)
      }
      let verifiedMetadata = try LegacySourceFileMetadata(
        validating: fileMetadata,
        name: name,
        maximumBytes: maximumBytes
      )
      try validateUnchanged()
      try validateForbiddenSiblings(forbiddenSiblingNames)
      try validateEntry(name: name, expectedMetadata: verifiedMetadata)
      return LegacyVerifiedSourceFile(
        name: name,
        descriptor: fileDescriptor,
        metadata: verifiedMetadata,
        directory: self,
        forbiddenSiblingNames: forbiddenSiblingNames
      )
    } catch {
      close(fileDescriptor)
      throw error
    }
  }
}

final class LegacyVerifiedSourceFile {
  let name: String

  private let descriptor: Int32
  private let metadata: LegacySourceFileMetadata
  private let directory: LegacyVerifiedSourceDirectory
  private let forbiddenSiblingNames: [String]

  fileprivate init(
    name: String,
    descriptor: Int32,
    metadata: LegacySourceFileMetadata,
    directory: LegacyVerifiedSourceDirectory,
    forbiddenSiblingNames: [String]
  ) {
    self.name = name
    self.descriptor = descriptor
    self.metadata = metadata
    self.directory = directory
    self.forbiddenSiblingNames = forbiddenSiblingNames
  }

  deinit {
    close(descriptor)
  }

  var descriptorPath: String {
    "/dev/fd/\(descriptor)"
  }

  func read(maximumBytes: Int) throws -> Data {
    guard maximumBytes > 0, maximumBytes <= metadata.maximumBytes else {
      throw LegacyImportError.readFailed
    }
    try validateUnchanged()

    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
    var offset: off_t = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        pread(descriptor, bytes.baseAddress, bytes.count, offset)
      }
      if count == 0 { break }
      if count < 0, errno == EINTR { continue }
      guard count > 0, count <= maximumBytes - result.count else {
        throw LegacyImportError.readFailed
      }
      result.append(contentsOf: buffer.prefix(count))
      offset += off_t(count)
    }

    try validateUnchanged()
    return result
  }

  func validateUnchanged() throws {
    try directory.validateUnchanged()
    try directory.validateForbiddenSiblings(forbiddenSiblingNames)

    var currentMetadata = stat()
    guard fstat(descriptor, &currentMetadata) == 0,
      try LegacySourceFileMetadata(
        validating: currentMetadata,
        name: name,
        maximumBytes: metadata.maximumBytes
      ) == metadata
    else {
      throw LegacyImportError.insecureSourceFile(name)
    }
    try directory.validateEntry(name: name, expectedMetadata: metadata)
  }

  fileprivate func validateRollbackJournalSQLiteHeader() throws {
    try validateUnchanged()
    var header = [UInt8](repeating: 0, count: 20)
    var offset = 0
    while offset < header.count {
      let count = header.withUnsafeMutableBytes { bytes in
        pread(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset,
          off_t(offset)
        )
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw LegacyImportError.corruptRepository }
      offset += count
    }
    let expectedMagic = Array("SQLite format 3\0".utf8)
    guard Array(header.prefix(expectedMagic.count)) == expectedMagic else {
      throw LegacyImportError.corruptRepository
    }
    guard header[18] == 1, header[19] == 1 else {
      throw LegacyImportError.insecureSourceFile(name)
    }
    try validateUnchanged()
  }
}

private struct LegacySourceDirectoryMetadata: Equatable {
  let device: dev_t
  let inode: ino_t
  let owner: uid_t
  let mode: mode_t

  init(validating metadata: stat) throws {
    guard metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o777 == 0o700
    else {
      throw LegacyImportError.insecureSourceDirectory
    }
    device = metadata.st_dev
    inode = metadata.st_ino
    owner = metadata.st_uid
    mode = metadata.st_mode
  }
}

private struct LegacySourceFileMetadata: Equatable {
  let device: dev_t
  let inode: ino_t
  let owner: uid_t
  let mode: mode_t
  let linkCount: nlink_t
  let size: off_t
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64
  let maximumBytes: Int

  init(
    validating metadata: stat,
    name: String,
    maximumBytes: Int
  ) throws {
    guard maximumBytes > 0,
      metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_mode & 0o777 == 0o600,
      metadata.st_nlink == 1,
      metadata.st_size > 0,
      metadata.st_size <= off_t(maximumBytes)
    else {
      throw LegacyImportError.insecureSourceFile(name)
    }
    device = metadata.st_dev
    inode = metadata.st_ino
    owner = metadata.st_uid
    mode = metadata.st_mode
    linkCount = metadata.st_nlink
    size = metadata.st_size
    modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
    modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
    changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
    changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    self.maximumBytes = maximumBytes
  }
}
