import Darwin
import Foundation

struct GitAttributeScanner {
  private let maximumEntries = 100_000
  private let maximumAttributeFiles = 1_024
  private let maximumFileBytes = 256 * 1_024
  private let maximumTotalBytes = 1_024 * 1_024
  private let maximumDepth = 128
  private var visitedEntries = 0
  private var totalBytes = 0
  private var files: [Data] = []

  mutating func scan(rootDescriptor: Int32) throws -> [Data] {
    try scanDirectory(descriptor: rootDescriptor, depth: 0)
    return files
  }

  private mutating func scanDirectory(descriptor: Int32, depth: Int) throws {
    guard depth <= maximumDepth else { throw GitEvidenceError.pathByteLimitExceeded }
    let duplicate = dup(descriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { Darwin.close(duplicate) }
      throw GitEvidenceError.unsafeGitAttributes
    }
    defer { closedir(directory) }

    errno = 0
    while let entry = readdir(directory) {
      let name = Self.entryName(entry)
      if name == "." || name == ".." { continue }
      try inspect(name: name, in: descriptor, depth: depth)
      errno = 0
    }
    guard errno == 0 else { throw GitEvidenceError.unsafeGitAttributes }
  }

  private mutating func inspect(
    name: String,
    in directoryDescriptor: Int32,
    depth: Int
  ) throws {
    visitedEntries += 1
    guard visitedEntries <= maximumEntries else {
      throw GitEvidenceError.fileCountLimitExceeded
    }
    var information = stat()
    let result = name.withCString {
      fstatat(directoryDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else { throw GitEvidenceError.unsafeGitAttributes }
    let type = information.st_mode & S_IFMT
    if type == S_IFDIR, name != ".git" {
      try scanChildDirectory(name: name, in: directoryDescriptor, depth: depth + 1)
      return
    }
    guard type == S_IFREG, name == ".gitattributes" else { return }
    try appendAttributeFile(name: name, in: directoryDescriptor)
  }

  private mutating func scanChildDirectory(
    name: String,
    in directoryDescriptor: Int32,
    depth: Int
  ) throws {
    let child = name.withCString {
      openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard child >= 0 else { throw GitEvidenceError.unsafeGitAttributes }
    defer { Darwin.close(child) }
    try scanDirectory(descriptor: child, depth: depth)
  }

  private mutating func appendAttributeFile(
    name: String,
    in directoryDescriptor: Int32
  ) throws {
    guard files.count < maximumAttributeFiles else {
      throw GitEvidenceError.fileCountLimitExceeded
    }
    let descriptor = name.withCString {
      openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw GitEvidenceError.unsafeGitAttributes }
    defer { Darwin.close(descriptor) }
    let contents = try Self.read(
      descriptor: descriptor,
      maximumBytes: maximumFileBytes
    )
    guard totalBytes <= maximumTotalBytes - contents.count else {
      throw GitEvidenceError.commandOutputLimitExceeded
    }
    totalBytes += contents.count
    files.append(contents)
  }

  private static func read(descriptor: Int32, maximumBytes: Int) throws -> Data {
    var information = stat()
    guard fstat(descriptor, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG,
      information.st_size >= 0,
      information.st_size <= maximumBytes
    else {
      throw GitEvidenceError.unsafeGitAttributes
    }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while output.count <= maximumBytes {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { return output }
      if count > 0 {
        output.append(contentsOf: buffer.prefix(count))
        continue
      }
      if errno == EINTR { continue }
      throw GitEvidenceError.unsafeGitAttributes
    }
    throw GitEvidenceError.unsafeGitAttributes
  }

  private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: &entry.pointee.d_name) { name in
      name.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
        String(cString: $0)
      }
    }
  }
}
