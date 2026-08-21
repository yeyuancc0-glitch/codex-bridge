import CryptoKit
import Darwin
import Foundation

public actor GitPatchStore {
  private static let processLock = NSLock()
  private static let lockWaitNanoseconds: UInt64 = 10_000_000
  private static let maximumLockAttempts = 500
  private static let lockFileName = ".patch-store.lock"
  private static let commitMarkerPrefix = ".commit_"
  private static let trashPrefix = ".trash_"

  private struct Document: Sendable {
    let byteCount: Int
    var lastAccess: Date
    var verifiedBytes: Data?
  }

  private let maximumDocumentCount: Int
  private let maximumStoredBytes: Int
  private let maximumPageBytes: Int
  private let persistentDirectory: URL?
  private let directoryDescriptor: Int32?
  private let lockDescriptor: Int32?
  private let committedRemovalHook: (@Sendable (URL, [String]) -> Void)?
  private var documents: [String: Document]
  private var storedBytes: Int

  public init(
    maximumDocumentCount: Int = 64,
    maximumStoredBytes: Int = 64 * 1_024 * 1_024,
    maximumPageBytes: Int = 200 * 1_024
  ) {
    self.maximumDocumentCount = max(1, maximumDocumentCount)
    self.maximumStoredBytes = max(1, maximumStoredBytes)
    self.maximumPageBytes = max(1, maximumPageBytes)
    persistentDirectory = nil
    directoryDescriptor = nil
    lockDescriptor = nil
    committedRemovalHook = nil
    documents = [:]
    storedBytes = 0
  }

  public init(
    persistentDirectory: URL,
    maximumDocumentCount: Int = 64,
    maximumStoredBytes: Int = 64 * 1_024 * 1_024,
    maximumPageBytes: Int = 200 * 1_024
  ) throws {
    try self.init(
      persistentDirectory: persistentDirectory,
      maximumDocumentCount: maximumDocumentCount,
      maximumStoredBytes: maximumStoredBytes,
      maximumPageBytes: maximumPageBytes,
      committedRemovalHook: nil
    )
  }

  init(
    persistentDirectory: URL,
    maximumDocumentCount: Int,
    maximumStoredBytes: Int,
    maximumPageBytes: Int,
    committedRemovalHook: (@Sendable (URL, [String]) -> Void)?
  ) throws {
    let documentLimit = max(1, maximumDocumentCount)
    let storedBytesLimit = max(1, maximumStoredBytes)
    self.maximumDocumentCount = documentLimit
    self.maximumStoredBytes = storedBytesLimit
    self.maximumPageBytes = max(1, maximumPageBytes)
    let descriptor = try Self.openPrivateDirectory(persistentDirectory)
    let lock = try Self.openLockFile(in: descriptor)
    do {
      let bounded = try Self.withExclusiveLock(lock) {
        var loaded = try Self.loadDocuments(
          directory: persistentDirectory,
          descriptor: descriptor
        )
        try Self.trimLoadedDocuments(
          &loaded,
          documentLimit: documentLimit,
          storedBytesLimit: storedBytesLimit,
          descriptor: descriptor
        )
        return loaded
      }
      self.persistentDirectory = persistentDirectory
      directoryDescriptor = descriptor
      lockDescriptor = lock
      self.committedRemovalHook = committedRemovalHook
      documents = bounded
      storedBytes = try Self.totalBytes(in: bounded)
    } catch {
      close(lock)
      close(descriptor)
      throw error
    }
  }

  deinit {
    if let lockDescriptor { close(lockDescriptor) }
    if let directoryDescriptor { close(directoryDescriptor) }
  }

  func store(_ bytes: Data, isTruncated: Bool) throws -> GitPatchHandle {
    try withStoreLock {
      try reloadPersistentDocuments()
      return try storeLocked(bytes, isTruncated: isTruncated)
    }
  }

  private func storeLocked(_ bytes: Data, isTruncated: Bool) throws -> GitPatchHandle {
    guard bytes.count <= maximumStoredBytes else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    let identifier = Self.identifier(for: bytes)
    if let existing = documents[identifier] {
      guard existing.byteCount == bytes.count else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      documents[identifier]?.lastAccess = Date()
      return GitPatchHandle(
        rawValue: identifier,
        totalBytes: bytes.count,
        isTruncated: isTruncated
      )
    }
    if let directoryDescriptor {
      try Self.write(bytes, named: identifier, to: directoryDescriptor)
      guard fsync(directoryDescriptor) == 0 else {
        _ = unlinkat(directoryDescriptor, identifier, 0)
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }
    documents[identifier] = Document(
      byteCount: bytes.count,
      lastAccess: Date(),
      verifiedBytes: directoryDescriptor == nil ? bytes : nil
    )
    storedBytes += bytes.count
    do {
      try trimToLimits(protecting: identifier)
    } catch {
      rollbackNewDocument(identifier)
      throw error
    }
    return GitPatchHandle(
      rawValue: identifier,
      totalBytes: bytes.count,
      isTruncated: isTruncated
    )
  }

  public func page(
    for handle: GitPatchHandle,
    offset: Int = 0,
    maximumBytes requestedMaximumBytes: Int? = nil
  ) throws -> GitPatchPage {
    try withStoreLock {
      try reloadPersistentDocuments()
      return try pageLocked(
        for: handle,
        offset: offset,
        maximumBytes: requestedMaximumBytes
      )
    }
  }

  private func pageLocked(
    for handle: GitPatchHandle,
    offset: Int,
    maximumBytes requestedMaximumBytes: Int?
  ) throws -> GitPatchPage {
    guard var document = documents[handle.rawValue], document.byteCount == handle.totalBytes else {
      throw GitEvidenceError.patchNotFound
    }
    guard offset >= 0, offset <= document.byteCount else {
      throw GitEvidenceError.invalidPatchCursor
    }
    let bytes: Data
    if let verifiedBytes = document.verifiedBytes {
      bytes = verifiedBytes
    } else {
      bytes = try loadAndVerify(handle.rawValue, document: document)
      document.verifiedBytes = bytes
    }
    let requested = requestedMaximumBytes.map { max(1, $0) } ?? maximumPageBytes
    let pageBytes = min(requested, maximumPageBytes)
    let end = min(bytes.count, offset + pageBytes)
    document.lastAccess = Date()
    documents[handle.rawValue] = document
    try persistLastAccess(handle.rawValue, document: document)
    return GitPatchPage(
      bytes: Data(bytes[offset..<end]),
      nextOffset: end < bytes.count ? end : nil,
      totalBytes: bytes.count,
      isTruncated: handle.isTruncated
    )
  }

  public func discard(_ handle: GitPatchHandle) {
    _ = try? remove(handle)
  }

  @discardableResult
  public func remove(_ handle: GitPatchHandle) throws -> Bool {
    try Self.validate(handle)
    return try withStoreLock {
      try reloadPersistentDocuments()
      guard let document = documents[handle.rawValue] else { return false }
      guard document.byteCount == handle.totalBytes else {
        throw GitEvidenceError.patchNotFound
      }
      if let directoryDescriptor {
        try Self.validateRemovable(
          [(handle.rawValue, document)],
          descriptor: directoryDescriptor
        )
        let hook: (([String]) -> Void)?
        if let committedRemovalHook, let persistentDirectory {
          hook = { temporaryNames in
            committedRemovalHook(persistentDirectory, temporaryNames)
          }
        } else {
          hook = nil
        }
        try Self.removeTransaction(
          [handle.rawValue],
          descriptor: directoryDescriptor,
          committedRemovalHook: hook
        )
      }
      documents[handle.rawValue] = nil
      storedBytes -= document.byteCount
      return true
    }
  }

  public func discardAll() {
    do {
      try withStoreLock {
        try reloadPersistentDocuments()
        let victims = Array(documents)
        if let directoryDescriptor, !victims.isEmpty {
          try Self.validateRemovable(victims, descriptor: directoryDescriptor)
          try Self.removeTransaction(victims.map(\.key), descriptor: directoryDescriptor)
        }
        documents.removeAll(keepingCapacity: false)
        storedBytes = 0
      }
    } catch {}
  }

  private func loadAndVerify(_ identifier: String, document: Document) throws -> Data {
    guard let directoryDescriptor, Self.validIdentifier(identifier) else {
      throw GitEvidenceError.patchNotFound
    }
    let descriptor = openat(directoryDescriptor, identifier, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw GitEvidenceError.patchNotFound }
    defer { close(descriptor) }
    let bytes = try Self.readBounded(descriptor, expectedCount: document.byteCount)
    guard identifier.hasSuffix("_\(Self.digest(for: bytes))") else {
      throw GitEvidenceError.patchNotFound
    }
    return bytes
  }

  private func persistLastAccess(_ identifier: String, document: Document) throws {
    guard let directoryDescriptor else { return }
    let descriptor = openat(directoryDescriptor, identifier, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw GitEvidenceError.patchNotFound }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
      metadata.st_size == document.byteCount
    else { throw GitEvidenceError.patchNotFound }
    guard futimens(descriptor, nil) == 0 else { throw GitEvidenceError.patchNotFound }
  }

  private func trimToLimits(protecting identifier: String) throws {
    guard let directoryDescriptor else {
      while documents.count > maximumDocumentCount || storedBytes > maximumStoredBytes {
        guard
          let oldest = documents.filter({ $0.key != identifier }).min(by: {
            $0.value.lastAccess < $1.value.lastAccess
          })
        else { throw GitEvidenceError.patchStoreCapacityExceeded }
        documents[oldest.key] = nil
        storedBytes -= oldest.value.byteCount
      }
      return
    }
    try Self.trimLoadedDocuments(
      &documents,
      documentLimit: maximumDocumentCount,
      storedBytesLimit: maximumStoredBytes,
      descriptor: directoryDescriptor,
      protecting: identifier
    )
    storedBytes = try Self.totalBytes(in: documents)
  }

  private func rollbackNewDocument(_ identifier: String) {
    guard let document = documents.removeValue(forKey: identifier) else { return }
    storedBytes -= document.byteCount
    guard let directoryDescriptor else { return }
    _ = unlinkat(directoryDescriptor, identifier, 0)
    _ = fsync(directoryDescriptor)
  }

  private func withStoreLock<Result>(_ body: () throws -> Result) throws -> Result {
    guard let lockDescriptor else { return try body() }
    return try Self.withExclusiveLock(lockDescriptor, body)
  }

  private func reloadPersistentDocuments() throws {
    guard let persistentDirectory, let directoryDescriptor else { return }
    let cached = documents
    var loaded = try Self.loadDocuments(
      directory: persistentDirectory,
      descriptor: directoryDescriptor
    )
    for (identifier, document) in cached {
      guard loaded[identifier]?.byteCount == document.byteCount else { continue }
      loaded[identifier]?.verifiedBytes = document.verifiedBytes
    }
    documents = loaded
    storedBytes = try Self.totalBytes(in: loaded)
  }

  private static func withExclusiveLock<Result>(
    _ descriptor: Int32,
    _ body: () throws -> Result
  ) throws -> Result {
    processLock.lock()
    defer { processLock.unlock() }
    try acquireExclusiveLock(descriptor)
    defer { releaseLock(descriptor) }
    return try body()
  }

  private static func acquireExclusiveLock(_ descriptor: Int32) throws {
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    for _ in 0..<maximumLockAttempts {
      if fcntl(descriptor, F_SETLK, &lock) == 0 { return }
      guard errno == EACCES || errno == EAGAIN else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      Thread.sleep(forTimeInterval: Double(lockWaitNanoseconds) / 1_000_000_000)
    }
    throw GitEvidenceError.patchStoreCapacityExceeded
  }

  private static func releaseLock(_ descriptor: Int32) {
    var lock = flock()
    lock.l_type = Int16(F_UNLCK)
    lock.l_whence = Int16(SEEK_SET)
    _ = fcntl(descriptor, F_SETLK, &lock)
  }

  private static func trimLoadedDocuments(
    _ documents: inout [String: Document],
    documentLimit: Int,
    storedBytesLimit: Int,
    descriptor: Int32,
    protecting protectedIdentifier: String? = nil
  ) throws {
    var remaining = documents
    var remainingBytes = try totalBytes(in: remaining)
    var victims: [(String, Document)] = []
    while remaining.count > documentLimit || remainingBytes > storedBytesLimit {
      guard
        let victim = remaining.filter({ $0.key != protectedIdentifier }).min(by: {
          let leftOversized = $0.value.byteCount > storedBytesLimit
          let rightOversized = $1.value.byteCount > storedBytesLimit
          if leftOversized != rightOversized { return leftOversized }
          return $0.value.lastAccess < $1.value.lastAccess
        })
      else { throw GitEvidenceError.patchStoreCapacityExceeded }
      victims.append(victim)
      remaining[victim.key] = nil
      remainingBytes -= victim.value.byteCount
    }
    guard !victims.isEmpty else { return }
    try validateRemovable(victims, descriptor: descriptor)
    try removeTransaction(victims.map(\.0), descriptor: descriptor)
    documents = remaining
  }

  private static func validateRemovable(
    _ victims: [(String, Document)],
    descriptor: Int32
  ) throws {
    let immutableFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
    for (identifier, document) in victims {
      let file = openat(descriptor, identifier, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard file >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      defer { close(file) }
      var metadata = stat()
      guard fstat(file, &metadata) == 0, metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
        metadata.st_size == document.byteCount,
        metadata.st_flags & immutableFlags == 0
      else { throw GitEvidenceError.patchStoreCapacityExceeded }
    }
  }

  private static func removeTransaction(
    _ identifiers: [String],
    descriptor: Int32,
    committedRemovalHook: (([String]) -> Void)? = nil
  ) throws {
    let transaction = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var staged: [(original: String, temporary: String)] = []
    do {
      for identifier in identifiers {
        let temporary = ".trash_\(transaction)_\(identifier)"
        guard renameat(descriptor, identifier, descriptor, temporary) == 0 else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        staged.append((identifier, temporary))
      }
      guard fsync(descriptor) == 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      try writeCommitMarker(transaction, descriptor: descriptor)
    } catch {
      restoreStaged(staged, descriptor: descriptor)
      throw error
    }
    committedRemovalHook?(staged.map(\.temporary))
    _ = cleanupCommittedTransaction(transaction, staged: staged, descriptor: descriptor)
  }

  private static func restoreStaged(
    _ staged: [(original: String, temporary: String)],
    descriptor: Int32
  ) {
    for item in staged.reversed() {
      _ = renameat(descriptor, item.temporary, descriptor, item.original)
    }
    _ = fsync(descriptor)
  }

  private static func writeCommitMarker(_ transaction: String, descriptor: Int32) throws {
    let name = commitMarkerPrefix + transaction
    let marker = openat(
      descriptor,
      name,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard marker >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
    defer { close(marker) }
    guard fchmod(marker, S_IRUSR | S_IWUSR) == 0, fsync(marker) == 0,
      fsync(descriptor) == 0
    else {
      _ = unlinkat(descriptor, name, 0)
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
  }

  private static func cleanupCommittedTransaction(
    _ transaction: String,
    staged: [(original: String, temporary: String)],
    descriptor: Int32
  ) -> Bool {
    for item in staged.sorted(by: { $0.temporary < $1.temporary }) {
      guard unlinkat(descriptor, item.temporary, 0) == 0 || errno == ENOENT else {
        return false
      }
    }
    let marker = commitMarkerPrefix + transaction
    guard unlinkat(descriptor, marker, 0) == 0 || errno == ENOENT else { return false }
    return fsync(descriptor) == 0
  }

  private static func totalBytes(in documents: [String: Document]) throws -> Int {
    try documents.values.reduce(into: 0) { total, document in
      let addition = total.addingReportingOverflow(document.byteCount)
      guard !addition.overflow else { throw GitEvidenceError.patchStoreCapacityExceeded }
      total = addition.partialValue
    }
  }

  private static func identifier(for bytes: Data) -> String {
    let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    return "patch_\(random)_\(digest(for: bytes))"
  }

  private static func digest(for bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func validIdentifier(_ value: String) -> Bool {
    let parts = value.split(separator: "_", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "patch", parts[1].count == 32, parts[2].count == 64
    else { return false }
    return parts.dropFirst().joined().unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    }
  }

  package static func validate(_ handle: GitPatchHandle) throws {
    guard validIdentifier(handle.rawValue), handle.totalBytes >= 0 else {
      throw GitEvidenceError.patchNotFound
    }
  }

  private static func openPrivateDirectory(_ url: URL) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
    } catch {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700
    else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
    return descriptor
  }

  private static func openLockFile(in descriptor: Int32) throws -> Int32 {
    let lock = openat(
      descriptor,
      lockFileName,
      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard lock >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
    var metadata = stat()
    guard fstat(lock, &metadata) == 0, metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFREG,
      fchmod(lock, S_IRUSR | S_IWUSR) == 0
    else {
      close(lock)
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    return lock
  }

  private static func loadDocuments(
    directory: URL,
    descriptor: Int32
  ) throws -> [String: Document] {
    try recoverStagedDocuments(directory: directory, descriptor: descriptor)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0 != lockFileName
    }
    guard names.count <= 1_024, names.allSatisfy(validIdentifier) else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    var result: [String: Document] = [:]
    for name in names {
      let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard file >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      defer { close(file) }
      var metadata = stat()
      guard fstat(file, &metadata) == 0, metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
        metadata.st_size >= 0, let byteCount = Int(exactly: metadata.st_size)
      else { throw GitEvidenceError.patchStoreCapacityExceeded }
      result[name] = Document(
        byteCount: byteCount,
        lastAccess: Date(
          timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
            + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        ),
        verifiedBytes: nil
      )
    }
    return result
  }

  private static func recoverStagedDocuments(directory: URL, descriptor: Int32) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    guard names.count <= 1_024 else { throw GitEvidenceError.patchStoreCapacityExceeded }
    var markers = Set<String>()
    var transactions: [String: [(original: String, temporary: String)]] = [:]
    for name in names where name.hasPrefix(commitMarkerPrefix) {
      let transaction = String(name.dropFirst(commitMarkerPrefix.count))
      guard validTransactionID(transaction) else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      try validateCommitMarker(name, descriptor: descriptor)
      markers.insert(transaction)
    }
    for temporary in names where temporary.hasPrefix(trashPrefix) {
      let (transaction, original) = try parseTrashName(temporary)
      transactions[transaction, default: []].append((original, temporary))
    }
    var changed = false
    for (transaction, staged) in transactions {
      if markers.remove(transaction) != nil {
        guard
          cleanupCommittedTransaction(
            transaction,
            staged: staged,
            descriptor: descriptor
          )
        else { throw GitEvidenceError.patchStoreCapacityExceeded }
      } else {
        for item in staged {
          var metadata = stat()
          guard fstatat(descriptor, item.original, &metadata, AT_SYMLINK_NOFOLLOW) != 0,
            errno == ENOENT,
            renameat(descriptor, item.temporary, descriptor, item.original) == 0
          else { throw GitEvidenceError.patchStoreCapacityExceeded }
        }
        changed = true
      }
    }
    for transaction in markers {
      guard cleanupCommittedTransaction(transaction, staged: [], descriptor: descriptor) else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }
    if changed, fsync(descriptor) != 0 {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
  }

  private static func validTransactionID(_ value: String) -> Bool {
    value.count == 32
      && value.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      }
  }

  private static func parseTrashName(_ temporary: String) throws -> (String, String) {
    let remainder = temporary.dropFirst(trashPrefix.count)
    guard let separator = remainder.firstIndex(of: "_") else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    let transaction = String(remainder[..<separator])
    let original = String(remainder[remainder.index(after: separator)...])
    guard validTransactionID(transaction), validIdentifier(original) else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    return (transaction, original)
  }

  private static func validateCommitMarker(_ name: String, descriptor: Int32) throws {
    let marker = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard marker >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
    defer { close(marker) }
    var metadata = stat()
    guard fstat(marker, &metadata) == 0, metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
      metadata.st_size == 0
    else { throw GitEvidenceError.patchStoreCapacityExceeded }
  }

  private static func write(_ bytes: Data, named name: String, to directory: Int32) throws {
    let descriptor = openat(
      directory,
      name,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
    var shouldRemove = true
    defer {
      close(descriptor)
      if shouldRemove { _ = unlinkat(directory, name, 0) }
    }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        guard written > 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
        offset += written
      }
    }
    guard fsync(descriptor) == 0 else { throw GitEvidenceError.patchStoreCapacityExceeded }
    shouldRemove = false
  }

  private static func readBounded(_ descriptor: Int32, expectedCount: Int) throws -> Data {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
      metadata.st_size == expectedCount
    else { throw GitEvidenceError.patchNotFound }
    var data = Data(count: expectedCount)
    let count = try data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let received = Darwin.read(
          descriptor,
          buffer.baseAddress! + offset,
          buffer.count - offset
        )
        guard received > 0 else { throw GitEvidenceError.patchNotFound }
        offset += received
      }
      return offset
    }
    guard count == expectedCount else { throw GitEvidenceError.patchNotFound }
    return data
  }
}
