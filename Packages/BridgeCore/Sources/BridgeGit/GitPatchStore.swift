import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif

#if os(Windows)
  private final class PatchStoreLockHandle: @unchecked Sendable {
    let raw: HANDLE

    init(_ raw: HANDLE) {
      self.raw = raw
    }

    deinit {
      if raw != INVALID_HANDLE_VALUE { _ = CloseHandle(raw) }
    }
  }

  /// WinSDK primitives backing GitPatchStore on Windows; the POSIX code paths
  /// keep using descriptor-based calls.
  private enum PatchStoreFile {
    static func openForReading(_ path: String) -> HANDLE {
      path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
    }

    /// O_CREAT | O_EXCL equivalent.
    static func createExclusive(_ path: String) -> HANDLE {
      path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(GENERIC_WRITE),
          0,
          nil,
          DWORD(CREATE_NEW),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
    }

    /// O_RDWR | O_CREAT equivalent.
    static func openReadWriteOrCreate(_ path: String) -> HANDLE {
      path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          // GENERIC_READ | GENERIC_WRITE
          DWORD(0x8000_0000) | DWORD(0x4000_0000),
          0,
          nil,
          DWORD(OPEN_ALWAYS),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
    }

    static func openDirectory(_ path: String) -> HANDLE {
      path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(FILE_READ_ATTRIBUTES),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
    }

    struct Information {
      var device: UInt64
      var inode: UInt64
      var size: Int64
      var attributes: DWORD
      var lastWriteFileTime: UInt64
    }

    static func information(_ handle: HANDLE) -> Information? {
      var data = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &data) else { return nil }
      let lastWrite = data.ftLastWriteTime
      return Information(
        device: UInt64(data.dwVolumeSerialNumber),
        inode: (UInt64(data.nFileIndexHigh) << 32) | UInt64(data.nFileIndexLow),
        size: Int64(bitPattern: (UInt64(data.nFileSizeHigh) << 32) | UInt64(data.nFileSizeLow)),
        attributes: data.dwFileAttributes,
        lastWriteFileTime: (UInt64(lastWrite.dwHighDateTime) << 32)
          | UInt64(lastWrite.dwLowDateTime)
      )
    }

    static func isRegularFile(_ attributes: DWORD) -> Bool {
      attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
    }

    static func remove(_ path: String) -> Bool {
      path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
    }

    static func rename(_ from: String, to: String) -> Bool {
      from.withCString(encodedAs: UTF16.self) { source in
        to.withCString(encodedAs: UTF16.self) { destination in
          MoveFileExW(source, destination, DWORD(MOVEFILE_REPLACE_EXISTING))
        }
      }
    }

    static func flush(_ handle: HANDLE) -> Bool {
      FlushFileBuffers(handle)
    }

    static func fsyncDirectory(_ path: String) -> Bool {
      let handle = openDirectory(path)
      guard handle != INVALID_HANDLE_VALUE else { return false }
      defer { _ = CloseHandle(handle) }
      return FlushFileBuffers(handle)
    }

    static func read(_ handle: HANDLE, expectedCount: Int) -> Data? {
      var data = Data(count: expectedCount)
      var receivedTotal = 0
      let completed = data.withUnsafeMutableBytes { raw -> Bool in
        while receivedTotal < expectedCount {
          var received: DWORD = 0
          let succeeded = ReadFile(
            handle,
            raw.baseAddress!.advanced(by: receivedTotal),
            DWORD(expectedCount - receivedTotal),
            &received,
            nil
          )
          guard succeeded, received > 0 else { return false }
          receivedTotal += Int(received)
        }
        return true
      }
      return completed ? data : nil
    }

    static func touchLastWrite(_ handle: HANDLE) -> Bool {
      var now = FILETIME()
      GetSystemTimeAsFileTime(&now)
      return SetFileTime(handle, nil, nil, &now)
    }

    static func acquireExclusiveLock(_ handle: HANDLE) -> Bool {
      var overlapped = OVERLAPPED()
      return LockFileEx(
        handle,
        DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY),
        0,
        DWORD.max,
        DWORD.max,
        &overlapped
      )
    }

    static func releaseLock(_ handle: HANDLE) {
      var overlapped = OVERLAPPED()
      _ = UnlockFileEx(handle, 0, DWORD.max, DWORD.max, &overlapped)
    }

    static func date(lastWriteFileTime raw: UInt64) -> Date {
      // FILETIME counts 100ns intervals since 1601-01-01.
      let unixEpochFileTime: UInt64 = 116_444_736_000_000_000
      guard raw >= unixEpochFileTime else { return Date(timeIntervalSince1970: 0) }
      return Date(timeIntervalSince1970: Double(raw - unixEpochFileTime) / 10_000_000)
    }
  }
#endif

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
  #if os(Windows)
    private var directoryPath: String?
    private var lockHandle: PatchStoreLockHandle?
  #else
    private let directoryDescriptor: Int32?
    private let lockDescriptor: Int32?
  #endif
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
    #if os(Windows)
      directoryPath = nil
      lockHandle = nil
    #else
      directoryDescriptor = nil
      lockDescriptor = nil
    #endif
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
    #if os(Windows)
      let directory = try Self.openPrivateDirectory(persistentDirectory)
      let lock = try Self.openLockFile(in: directory)
      do {
        let bounded = try Self.withExclusiveLock(lock) {
          var loaded = try Self.loadDocuments(directory: persistentDirectory, path: directory)
          try Self.trimLoadedDocuments(
            &loaded,
            documentLimit: documentLimit,
            storedBytesLimit: storedBytesLimit,
            path: directory
          )
          return loaded
        }
        self.persistentDirectory = persistentDirectory
        directoryPath = directory
        self.committedRemovalHook = committedRemovalHook
        documents = bounded
        storedBytes = try Self.totalBytes(in: bounded)
        lockHandle = PatchStoreLockHandle(lock)
      } catch {
        _ = CloseHandle(lock)
        throw error
      }
    #else
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
    #endif
  }

  deinit {
    #if !os(Windows)
      if let lockDescriptor { close(lockDescriptor) }
      if let directoryDescriptor { close(directoryDescriptor) }
    #endif
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
    #if os(Windows)
      if let directoryPath {
        try Self.write(bytes, named: identifier, in: directoryPath)
        guard PatchStoreFile.fsyncDirectory(directoryPath) else {
          _ = PatchStoreFile.remove(directoryPath + "\\" + identifier)
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
      }
      documents[identifier] = Document(
        byteCount: bytes.count,
        lastAccess: Date(),
        verifiedBytes: directoryPath == nil ? bytes : nil
      )
    #else
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
    #endif
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
      #if os(Windows)
        if let directoryPath {
          try Self.validateRemovable([(handle.rawValue, document)], path: directoryPath)
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
            path: directoryPath,
            committedRemovalHook: hook
          )
        }
      #else
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
      #endif
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
        #if os(Windows)
          if let directoryPath, !victims.isEmpty {
            try Self.validateRemovable(victims, path: directoryPath)
            try Self.removeTransaction(victims.map(\.key), path: directoryPath)
          }
        #else
          if let directoryDescriptor, !victims.isEmpty {
            try Self.validateRemovable(victims, descriptor: directoryDescriptor)
            try Self.removeTransaction(victims.map(\.key), descriptor: directoryDescriptor)
          }
        #endif
        documents.removeAll(keepingCapacity: false)
        storedBytes = 0
      }
    } catch {}
  }

  private func loadAndVerify(_ identifier: String, document: Document) throws -> Data {
    #if os(Windows)
      guard let directoryPath, Self.validIdentifier(identifier) else {
        throw GitEvidenceError.patchNotFound
      }
      let handle = PatchStoreFile.openForReading(directoryPath + "\\" + identifier)
      guard handle != INVALID_HANDLE_VALUE else { throw GitEvidenceError.patchNotFound }
      defer { _ = CloseHandle(handle) }
      let bytes = try Self.readBounded(handle, expectedCount: document.byteCount)
    #else
      guard let directoryDescriptor, Self.validIdentifier(identifier) else {
        throw GitEvidenceError.patchNotFound
      }
      let descriptor = openat(directoryDescriptor, identifier, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw GitEvidenceError.patchNotFound }
      defer { close(descriptor) }
      let bytes = try Self.readBounded(descriptor, expectedCount: document.byteCount)
    #endif
    guard identifier.hasSuffix("_\(Self.digest(for: bytes))") else {
      throw GitEvidenceError.patchNotFound
    }
    return bytes
  }

  private func persistLastAccess(_ identifier: String, document: Document) throws {
    #if os(Windows)
      guard let directoryPath else { return }
      let handle = PatchStoreFile.openForReading(directoryPath + "\\" + identifier)
      guard handle != INVALID_HANDLE_VALUE else { throw GitEvidenceError.patchNotFound }
      defer { _ = CloseHandle(handle) }
      // Windows uses ACLs; the POSIX owner/mode checks apply to POSIX only.
      guard let information = PatchStoreFile.information(handle),
        PatchStoreFile.isRegularFile(information.attributes),
        information.size == document.byteCount
      else { throw GitEvidenceError.patchNotFound }
      guard PatchStoreFile.touchLastWrite(handle) else {
        throw GitEvidenceError.patchNotFound
      }
    #else
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
    #endif
  }

  private func trimToLimits(protecting identifier: String) throws {
    #if os(Windows)
      guard let directoryPath else {
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
        path: directoryPath,
        protecting: identifier
      )
      storedBytes = try Self.totalBytes(in: documents)
    #else
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
    #endif
  }

  private func rollbackNewDocument(_ identifier: String) {
    guard let document = documents.removeValue(forKey: identifier) else { return }
    storedBytes -= document.byteCount
    #if os(Windows)
      guard let directoryPath else { return }
      _ = PatchStoreFile.remove(directoryPath + "\\" + identifier)
      _ = PatchStoreFile.fsyncDirectory(directoryPath)
    #else
      guard let directoryDescriptor else { return }
      _ = unlinkat(directoryDescriptor, identifier, 0)
      _ = fsync(directoryDescriptor)
    #endif
  }

  private func withStoreLock<Result>(_ body: () throws -> Result) throws -> Result {
    #if os(Windows)
      guard let lockHandle else { return try body() }
      return try Self.withExclusiveLock(lockHandle.raw, body)
    #else
      guard let lockDescriptor else { return try body() }
      return try Self.withExclusiveLock(lockDescriptor, body)
    #endif
  }

  private func reloadPersistentDocuments() throws {
    guard let persistentDirectory else { return }
    #if os(Windows)
      guard let directoryPath else { return }
      let cached = documents
      var loaded = try Self.loadDocuments(directory: persistentDirectory, path: directoryPath)
    #else
      guard let directoryDescriptor else { return }
      let cached = documents
      var loaded = try Self.loadDocuments(
        directory: persistentDirectory,
        descriptor: directoryDescriptor
      )
    #endif
    for (identifier, document) in cached {
      guard loaded[identifier]?.byteCount == document.byteCount else { continue }
      loaded[identifier]?.verifiedBytes = document.verifiedBytes
    }
    documents = loaded
    storedBytes = try Self.totalBytes(in: loaded)
  }

  #if os(Windows)
    private static func withExclusiveLock<Result>(
      _ lock: HANDLE,
      _ body: () throws -> Result
    ) throws -> Result {
      processLock.lock()
      defer { processLock.unlock() }
      guard PatchStoreFile.acquireExclusiveLock(lock) else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      defer { PatchStoreFile.releaseLock(lock) }
      return try body()
    }
  #endif

  #if !os(Windows)
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
  #endif

  #if os(Windows)
    private static func trimLoadedDocuments(
      _ documents: inout [String: Document],
      documentLimit: Int,
      storedBytesLimit: Int,
      path: String,
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
      try validateRemovable(victims, path: path)
      try removeTransaction(victims.map(\.0), path: path)
      documents = remaining
    }
  #endif

  #if os(Windows)
    private static func validateRemovable(
      _ victims: [(String, Document)],
      path: String
    ) throws {
      // Windows uses ACLs; the POSIX owner/mode/immutable-flag checks apply to
      // POSIX only.
      for (identifier, document) in victims {
        let file = PatchStoreFile.openForReading(path + "\\" + identifier)
        guard file != INVALID_HANDLE_VALUE else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        defer { _ = CloseHandle(file) }
        guard let information = PatchStoreFile.information(file),
          PatchStoreFile.isRegularFile(information.attributes),
          information.size == document.byteCount
        else { throw GitEvidenceError.patchStoreCapacityExceeded }
      }
    }
  #else
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
  #endif

  #if os(Windows)
    private static func removeTransaction(
      _ identifiers: [String],
      path: String,
      committedRemovalHook: (([String]) -> Void)? = nil
    ) throws {
      let transaction = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      var staged: [(original: String, temporary: String)] = []
      do {
        for identifier in identifiers {
          let temporary = ".trash_\(transaction)_\(identifier)"
          guard PatchStoreFile.rename(path + "\\" + identifier, to: path + "\\" + temporary)
          else {
            throw GitEvidenceError.patchStoreCapacityExceeded
          }
          staged.append((identifier, temporary))
        }
        guard PatchStoreFile.fsyncDirectory(path) else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        try writeCommitMarker(transaction, path: path)
      } catch {
        restoreStaged(staged, path: path)
        throw error
      }
      committedRemovalHook?(staged.map(\.temporary))
      _ = cleanupCommittedTransaction(transaction, staged: staged, path: path)
    }

    private static func restoreStaged(
      _ staged: [(original: String, temporary: String)],
      path: String
    ) {
      for item in staged.reversed() {
        _ = PatchStoreFile.rename(path + "\\" + item.temporary, to: path + "\\" + item.original)
      }
      _ = PatchStoreFile.fsyncDirectory(path)
    }

    private static func writeCommitMarker(_ transaction: String, path: String) throws {
      let name = commitMarkerPrefix + transaction
      let marker = PatchStoreFile.createExclusive(path + "\\" + name)
      guard marker != INVALID_HANDLE_VALUE else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      defer { _ = CloseHandle(marker) }
      guard PatchStoreFile.flush(marker), PatchStoreFile.fsyncDirectory(path) else {
        _ = PatchStoreFile.remove(path + "\\" + name)
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }

    private static func cleanupCommittedTransaction(
      _ transaction: String,
      staged: [(original: String, temporary: String)],
      path: String
    ) -> Bool {
      for item in staged.sorted(by: { $0.temporary < $1.temporary }) {
        guard
          PatchStoreFile.remove(path + "\\" + item.temporary)
            || GetLastError() == DWORD(ERROR_FILE_NOT_FOUND)
        else { return false }
      }
      let marker = commitMarkerPrefix + transaction
      guard
        PatchStoreFile.remove(path + "\\" + marker)
          || GetLastError() == DWORD(ERROR_FILE_NOT_FOUND)
      else { return false }
      return PatchStoreFile.fsyncDirectory(path)
    }
  #else
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
  #endif

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

  #if os(Windows)
    private static func openPrivateDirectory(_ url: URL) throws -> String {
      guard url.isFileURL else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      do {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: true
        )
      } catch {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      // Windows uses ACLs; the POSIX owner/mode checks apply to POSIX only.
      guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeDirectory
      else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      return url.path
    }

    private static func openLockFile(in path: String) throws -> HANDLE {
      let lock = PatchStoreFile.openReadWriteOrCreate(path + "\\" + lockFileName)
      guard lock != INVALID_HANDLE_VALUE else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      return lock
    }

    private static func loadDocuments(
      directory: URL,
      path: String
    ) throws -> [String: Document] {
      try recoverStagedDocuments(directory: directory, path: path)
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
        $0 != lockFileName
      }
      guard names.count <= 1_024, names.allSatisfy(validIdentifier) else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      var result: [String: Document] = [:]
      for name in names {
        let file = PatchStoreFile.openForReading(path + "\\" + name)
        guard file != INVALID_HANDLE_VALUE else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        defer { _ = CloseHandle(file) }
        // Windows uses ACLs; the POSIX owner/mode checks apply to POSIX only.
        guard let information = PatchStoreFile.information(file),
          PatchStoreFile.isRegularFile(information.attributes),
          information.size >= 0, let byteCount = Int(exactly: information.size)
        else { throw GitEvidenceError.patchStoreCapacityExceeded }
        result[name] = Document(
          byteCount: byteCount,
          lastAccess: PatchStoreFile.date(lastWriteFileTime: information.lastWriteFileTime),
          verifiedBytes: nil
        )
      }
      return result
    }

    private static func recoverStagedDocuments(directory: URL, path: String) throws {
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      guard names.count <= 1_024 else { throw GitEvidenceError.patchStoreCapacityExceeded }
      var markers = Set<String>()
      var transactions: [String: [(original: String, temporary: String)]] = [:]
      for name in names where name.hasPrefix(commitMarkerPrefix) {
        let transaction = String(name.dropFirst(commitMarkerPrefix.count))
        guard validTransactionID(transaction) else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
        try validateCommitMarker(name, path: path)
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
              path: path
            )
          else { throw GitEvidenceError.patchStoreCapacityExceeded }
        } else {
          for item in staged {
            let originalAttributes = (path + "\\" + item.original)
              .withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
            guard originalAttributes == INVALID_FILE_ATTRIBUTES,
              GetLastError() == DWORD(ERROR_FILE_NOT_FOUND),
              PatchStoreFile.rename(path + "\\" + item.temporary, to: path + "\\" + item.original)
            else { throw GitEvidenceError.patchStoreCapacityExceeded }
          }
          changed = true
        }
      }
      for transaction in markers {
        guard cleanupCommittedTransaction(transaction, staged: [], path: path) else {
          throw GitEvidenceError.patchStoreCapacityExceeded
        }
      }
      if changed, !PatchStoreFile.fsyncDirectory(path) {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
    }

    private static func validateCommitMarker(_ name: String, path: String) throws {
      let marker = PatchStoreFile.openForReading(path + "\\" + name)
      guard marker != INVALID_HANDLE_VALUE else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      defer { _ = CloseHandle(marker) }
      // Windows uses ACLs; the POSIX owner/mode checks apply to POSIX only.
      guard let information = PatchStoreFile.information(marker),
        PatchStoreFile.isRegularFile(information.attributes),
        information.size == 0
      else { throw GitEvidenceError.patchStoreCapacityExceeded }
    }

    private static func write(_ bytes: Data, named name: String, in path: String) throws {
      let handle = PatchStoreFile.createExclusive(path + "\\" + name)
      guard handle != INVALID_HANDLE_VALUE else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      var shouldRemove = true
      defer {
        _ = CloseHandle(handle)
        if shouldRemove { _ = PatchStoreFile.remove(path + "\\" + name) }
      }
      try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          var written: DWORD = 0
          let succeeded = WriteFile(
            handle,
            buffer.baseAddress! + offset,
            DWORD(buffer.count - offset),
            &written,
            nil
          )
          guard succeeded, written > 0 else {
            throw GitEvidenceError.patchStoreCapacityExceeded
          }
          offset += Int(written)
        }
      }
      guard PatchStoreFile.flush(handle) else {
        throw GitEvidenceError.patchStoreCapacityExceeded
      }
      shouldRemove = false
    }

    private static func readBounded(_ handle: HANDLE, expectedCount: Int) throws -> Data {
      // Windows uses ACLs; the POSIX owner/mode checks apply to POSIX only.
      guard let information = PatchStoreFile.information(handle),
        PatchStoreFile.isRegularFile(information.attributes),
        information.size == expectedCount
      else { throw GitEvidenceError.patchNotFound }
      guard let data = PatchStoreFile.read(handle, expectedCount: expectedCount) else {
        throw GitEvidenceError.patchNotFound
      }
      return data
    }
  #else
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
          let written = Darwin.write(
            descriptor, buffer.baseAddress! + offset, buffer.count - offset)
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
  #endif

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
}
