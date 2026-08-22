import Crypto
import Darwin
import Foundation

public enum DesktopBackupPackageError: Error, Equatable, Sendable {
  case invalidURL
  case invalidPackageName
  case destinationExists
  case unavailable
  case insecureRoot
  case insecureEntry(String)
  case missingEntry(String)
  case unexpectedEntry(String)
  case malformedManifest
  case unsupportedVersion(Int)
  case invalidManifest
  case entryTooLarge(String)
  case packageTooLarge
  case digestMismatch(String)
}

public enum DesktopBackupPackage {
  public static let schemaVersion = 1
  public static let manifestFileName = "manifest.json"
  public static let maximumManifestBytes = 64 * 1_024
  public static let maximumEntryBytes: Int64 = 256 * 1_024 * 1_024
  public static let maximumPackageBytes: Int64 = 512 * 1_024 * 1_024
  public static let allowedEntryNames: Set<String> = [
    "application.sqlite",
    "supervision-ledger.sqlite",
    "task-events.sqlite",
  ]

  public struct Manifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
      public let name: String
      public let byteCount: Int64
      public let sha256: String

      public init(name: String, byteCount: Int64, sha256: String) {
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
      }

      private enum CodingKeys: String, CodingKey {
        case name
        case byteCount = "byte_count"
        case sha256
      }
    }

    public let schemaVersion: Int
    public let createdAt: Date
    public let totalBytes: Int64
    public let entries: [Entry]

    public init(
      schemaVersion: Int,
      createdAt: Date,
      totalBytes: Int64,
      entries: [Entry]
    ) {
      self.schemaVersion = schemaVersion
      self.createdAt = createdAt
      self.totalBytes = totalBytes
      self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case createdAt = "created_at"
      case totalBytes = "total_bytes"
      case entries
    }
  }

  /// Packages caller-provided consistent database snapshots; it does not snapshot live SQLite.
  @discardableResult
  public static func create(
    from dataDirectoryURL: URL,
    at packageURL: URL,
    now: Date = Date()
  ) throws -> Manifest {
    try validateURL(dataDirectoryURL, directory: true)
    try validatePackageURL(packageURL)
    guard now.timeIntervalSince1970.isFinite else {
      throw DesktopBackupPackageError.invalidManifest
    }

    let source = try openDirectory(dataDirectoryURL, requirePrivate: true)
    defer { close(source) }
    let parent = try openParentDirectory(for: packageURL)
    defer { close(parent) }
    try ensureDestinationAbsent(packageURL, parent: parent)

    let temporaryName = ".codex-bridge-backup-\(UUID().uuidString.lowercased())"
    guard mkdirat(parent, temporaryName, S_IRWXU) == 0 else {
      throw DesktopBackupPackageError.unavailable
    }
    let temporaryURL = packageURL.deletingLastPathComponent()
      .appendingPathComponent(temporaryName, isDirectory: true)
    let temporary = try openDirectory(temporaryURL, requirePrivate: true)
    var published = false
    defer {
      close(temporary)
      if !published { removeTemporaryDirectory(temporaryName, parent: parent) }
    }

    var entries: [Manifest.Entry] = []
    var totalBytes: Int64 = 0
    for name in allowedEntryNames.sorted() {
      let bytes = try readSourceEntry(name, from: source)
      let byteCount = Int64(bytes.count)
      guard byteCount <= maximumEntryBytes else {
        throw DesktopBackupPackageError.entryTooLarge(name)
      }
      let (nextTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
      guard !overflow, nextTotal <= maximumPackageBytes else {
        throw DesktopBackupPackageError.packageTooLarge
      }
      try writeEntry(bytes, name: name, to: temporary)
      entries.append(
        Manifest.Entry(
          name: name,
          byteCount: byteCount,
          sha256: digest(bytes)
        )
      )
      totalBytes = nextTotal
    }

    let manifest = Manifest(
      schemaVersion: schemaVersion,
      createdAt: now,
      totalBytes: totalBytes,
      entries: entries
    )
    let manifestData = try encodeManifest(manifest)
    guard manifestData.count <= maximumManifestBytes else {
      throw DesktopBackupPackageError.invalidManifest
    }
    try writeEntry(manifestData, name: manifestFileName, to: temporary)
    guard fsync(temporary) == 0 else { throw DesktopBackupPackageError.unavailable }
    guard
      renameatx_np(
        parent,
        temporaryName,
        parent,
        packageURL.lastPathComponent,
        UInt32(RENAME_EXCL)
      ) == 0
    else {
      if errno == EEXIST { throw DesktopBackupPackageError.destinationExists }
      throw DesktopBackupPackageError.unavailable
    }
    published = true
    guard fsync(parent) == 0 else { throw DesktopBackupPackageError.unavailable }
    return manifest
  }

  public static func validate(at packageURL: URL) throws -> Manifest {
    try validatePackageURL(packageURL)
    let package = try openDirectory(packageURL, requirePrivate: true)
    defer { close(package) }

    let expectedNames = allowedEntryNames.union([manifestFileName])
    let actualNames = try childNames(at: packageURL)
    if let unexpected = actualNames.subtracting(expectedNames).sorted().first {
      throw DesktopBackupPackageError.unexpectedEntry(unexpected)
    }
    if let missing = expectedNames.subtracting(actualNames).sorted().first {
      throw DesktopBackupPackageError.missingEntry(missing)
    }

    let manifestData = try readEntry(
      manifestFileName, from: package, maximumBytes: maximumManifestBytes)
    let manifest: Manifest
    do {
      manifest = try decodeManifest(manifestData)
    } catch let error as DesktopBackupPackageError {
      throw error
    } catch {
      throw DesktopBackupPackageError.malformedManifest
    }
    try validateManifest(manifest)

    var totalBytes: Int64 = 0
    for entry in manifest.entries {
      let bytes = try readEntry(
        entry.name,
        from: package,
        maximumBytes: Int(min(maximumEntryBytes, Int64(Int.max)))
      )
      guard Int64(bytes.count) == entry.byteCount else {
        throw DesktopBackupPackageError.digestMismatch(entry.name)
      }
      guard digest(bytes) == entry.sha256 else {
        throw DesktopBackupPackageError.digestMismatch(entry.name)
      }
      let (nextTotal, overflow) = totalBytes.addingReportingOverflow(entry.byteCount)
      guard !overflow, nextTotal <= maximumPackageBytes else {
        throw DesktopBackupPackageError.packageTooLarge
      }
      totalBytes = nextTotal
    }
    guard totalBytes == manifest.totalBytes else {
      throw DesktopBackupPackageError.invalidManifest
    }
    return manifest
  }

  private static func validateManifest(_ manifest: Manifest) throws {
    guard manifest.schemaVersion == schemaVersion else {
      throw DesktopBackupPackageError.unsupportedVersion(manifest.schemaVersion)
    }
    guard manifest.createdAt.timeIntervalSince1970.isFinite,
      manifest.totalBytes >= 0,
      manifest.totalBytes <= maximumPackageBytes,
      manifest.entries.count == allowedEntryNames.count
    else {
      throw DesktopBackupPackageError.invalidManifest
    }

    var names = Set<String>()
    var totalBytes: Int64 = 0
    for entry in manifest.entries {
      guard allowedEntryNames.contains(entry.name), names.insert(entry.name).inserted,
        entry.byteCount >= 0, entry.byteCount <= maximumEntryBytes,
        isDigest(entry.sha256)
      else {
        throw DesktopBackupPackageError.invalidManifest
      }
      let (nextTotal, overflow) = totalBytes.addingReportingOverflow(entry.byteCount)
      guard !overflow, nextTotal <= maximumPackageBytes else {
        throw DesktopBackupPackageError.packageTooLarge
      }
      totalBytes = nextTotal
    }
    guard names == allowedEntryNames, totalBytes == manifest.totalBytes else {
      throw DesktopBackupPackageError.invalidManifest
    }
  }

  private static func readSourceEntry(_ name: String, from root: Int32) throws -> Data {
    let descriptor = openat(root, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { throw DesktopBackupPackageError.missingEntry(name) }
      throw DesktopBackupPackageError.insecureEntry(name)
    }
    defer { close(descriptor) }
    let initial = try validateRegularFile(descriptor, name: name)
    guard initial.st_size <= maximumEntryBytes else {
      throw DesktopBackupPackageError.entryTooLarge(name)
    }
    let bytes = try readAll(descriptor, maximumBytes: maximumEntryBytes, name: name)
    var final = stat()
    guard fstat(descriptor, &final) == 0,
      final.st_dev == initial.st_dev,
      final.st_ino == initial.st_ino,
      final.st_size == initial.st_size,
      Int64(bytes.count) == initial.st_size
    else {
      throw DesktopBackupPackageError.unavailable
    }
    return bytes
  }

  private static func writeEntry(_ bytes: Data, name: String, to directory: Int32) throws {
    let descriptor = openat(
      directory,
      name,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw DesktopBackupPackageError.unavailable }
    var complete = false
    defer {
      close(descriptor)
      if !complete { _ = unlinkat(directory, name, 0) }
    }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw DesktopBackupPackageError.unavailable
    }
    try writeAll(bytes, to: descriptor)
    guard fsync(descriptor) == 0 else { throw DesktopBackupPackageError.unavailable }
    complete = true
  }

  private static func readEntry(
    _ name: String,
    from directory: Int32,
    maximumBytes: Int
  ) throws -> Data {
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { throw DesktopBackupPackageError.missingEntry(name) }
      throw DesktopBackupPackageError.insecureEntry(name)
    }
    defer { close(descriptor) }
    _ = try validateRegularFile(descriptor, name: name)
    return try readAll(descriptor, maximumBytes: Int64(maximumBytes), name: name)
  }

  private static func validateRegularFile(_ descriptor: Int32, name: String) throws -> stat {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      (metadata.st_mode & 0o777) == 0o600,
      metadata.st_nlink == 1
    else {
      throw DesktopBackupPackageError.insecureEntry(name)
    }
    return metadata
  }

  private static func readAll(
    _ descriptor: Int32,
    maximumBytes: Int64,
    name: String
  ) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count == 0 { return data }
      if count < 0 {
        if errno == EINTR { continue }
        throw DesktopBackupPackageError.unavailable
      }
      let (nextCount, overflow) = data.count.addingReportingOverflow(count)
      guard !overflow, Int64(nextCount) <= maximumBytes else {
        throw DesktopBackupPackageError.entryTooLarge(name)
      }
      data.append(buffer, count: count)
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw DesktopBackupPackageError.unavailable }
        offset += count
      }
    }
  }

  private static func childNames(at packageURL: URL) throws -> Set<String> {
    do {
      return Set(
        try FileManager.default.contentsOfDirectory(
          at: packageURL,
          includingPropertiesForKeys: nil,
          options: []
        ).map(\.lastPathComponent))
    } catch {
      throw DesktopBackupPackageError.unavailable
    }
  }

  private static func encodeManifest(_ manifest: Manifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(manifest)
  }

  private static func decodeManifest(_ data: Data) throws -> Manifest {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Manifest.self, from: data)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }

  private static func validateURL(_ url: URL, directory: Bool) throws {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
      throw DesktopBackupPackageError.invalidURL
    }
    if directory {
      let descriptor = try openDirectory(url, requirePrivate: true)
      close(descriptor)
    }
  }

  private static func validatePackageURL(_ url: URL) throws {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
      let name = url.pathComponents.last,
      !name.isEmpty, name != ".", name != "..", !name.contains("/")
    else {
      throw DesktopBackupPackageError.invalidPackageName
    }
  }

  private static func openDirectory(_ url: URL, requirePrivate: Bool) throws -> Int32 {
    let descriptor = Darwin.open(
      url.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw DesktopBackupPackageError.insecureRoot }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == geteuid(),
      !requirePrivate || (metadata.st_mode & 0o777) == 0o700
    else {
      close(descriptor)
      throw DesktopBackupPackageError.insecureRoot
    }
    return descriptor
  }

  private static func openParentDirectory(for packageURL: URL) throws -> Int32 {
    let parent = packageURL.deletingLastPathComponent().resolvingSymlinksInPath()
      .standardizedFileURL
    let descriptor = Darwin.open(
      parent.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw DesktopBackupPackageError.unavailable }
    return descriptor
  }

  private static func ensureDestinationAbsent(_ url: URL, parent: Int32) throws {
    var metadata = stat()
    if lstat(url.path, &metadata) == 0 {
      throw DesktopBackupPackageError.destinationExists
    }
    guard errno == ENOENT else { throw DesktopBackupPackageError.unavailable }
    _ = parent
  }

  private static func removeTemporaryDirectory(_ name: String, parent: Int32) {
    guard let descriptor = try? openatDirectory(parent, name) else {
      _ = unlinkat(parent, name, AT_REMOVEDIR)
      return
    }
    for fileName in allowedEntryNames.union([manifestFileName]) {
      _ = unlinkat(descriptor, fileName, 0)
    }
    close(descriptor)
    _ = unlinkat(parent, name, AT_REMOVEDIR)
  }

  private static func openatDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
    let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw DesktopBackupPackageError.unavailable }
    return descriptor
  }
}
