import BridgeCoordinator
import BridgeDomain
import BridgeGit
import Crypto
import Darwin
import Foundation

public enum PipelinePreflightStoreError: Error, Equatable, Sendable {
  case invalidArgument(String)
  case unavailable
  case corruptStore
  case capacityExceeded
  case conflict(TaskID)
  case missing(TaskID)
}

public enum PipelinePreflightRetentionRemoval: Equatable, Sendable {
  case removed
  case alreadyAbsent
}

public protocol PipelinePreflightRetentionStore: Sendable {
  func discardForRetention(taskID: TaskID) async throws -> PipelinePreflightRetentionRemoval
}

public actor PipelinePreflightStore: PipelinePreflightRetentionStore {
  public static let maximumRecords = 256
  public static let maximumFileBytes = 2 * 1_024 * 1_024
  public static let maximumBaselineBytes = 512 * 1_024
  private static let processLock = NSLock()
  private static let lockWaitNanoseconds: UInt64 = 10_000_000
  private static let maximumLockAttempts = 500

  private let path: String?
  private var records: [String: PipelinePreflightRecord]

  public init(path: String) throws {
    guard !path.isEmpty, path.utf8.count <= 16_384, !path.contains("\0") else {
      throw PipelinePreflightStoreError.invalidArgument("path")
    }
    self.path = path
    records = try Self.load(path: path)
  }

  private init(records: [String: PipelinePreflightRecord]) {
    path = nil
    self.records = records
  }

  public static func inMemory() -> PipelinePreflightStore {
    PipelinePreflightStore(records: [:])
  }

  func storeBaseline(
    context: TaskPipelinePreStartContext,
    baseline: GitBaselineEvidence,
    at date: Date = Date()
  ) throws {
    let key = try PipelinePreflightKey(context: context)
    try Self.validate(baseline: baseline, key: key, at: date)
    try updateRecords { records in
      if let existing = records[key.taskID.rawValue] {
        guard existing.key == key, existing.baseline == baseline else {
          throw PipelinePreflightStoreError.conflict(key.taskID)
        }
        return
      }
      guard records.count < Self.maximumRecords else {
        throw PipelinePreflightStoreError.capacityExceeded
      }
      records[key.taskID.rawValue] = PipelinePreflightRecord(
        key: key,
        baseline: baseline,
        turnID: nil,
        capturedAt: date
      )
    }
  }

  func recordStartedTurn(_ context: TaskPipelineStartedContext) throws {
    let key = try PipelinePreflightKey(context: context.preStart)
    try updateRecords { records in
      guard var record = records[key.taskID.rawValue], record.key == key else {
        throw PipelinePreflightStoreError.missing(key.taskID)
      }
      guard context.binding.threadID == key.threadID,
        context.binding.turnGeneration == key.generation
      else { throw PipelinePreflightStoreError.conflict(key.taskID) }
      if let turnID = record.turnID {
        guard turnID == context.binding.turnID else {
          throw PipelinePreflightStoreError.conflict(key.taskID)
        }
        return
      }
      record = record.withTurnID(context.binding.turnID)
      records[key.taskID.rawValue] = record
    }
  }

  func startedRecord(taskID: TaskID, binding: ExecutionBinding) throws
    -> PipelinePreflightRecord
  {
    let records = try refreshedRecords()
    guard let record = records[taskID.rawValue] else {
      throw PipelinePreflightStoreError.missing(taskID)
    }
    guard record.key.threadID == binding.threadID,
      record.key.generation == binding.turnGeneration,
      record.turnID == binding.turnID
    else { throw PipelinePreflightStoreError.conflict(taskID) }
    return record
  }

  func allRecords() throws -> [PipelinePreflightRecord] {
    try refreshedRecords().values.sorted { $0.key.taskID.rawValue < $1.key.taskID.rawValue }
  }

  func discard(taskID: TaskID) throws {
    _ = try discardForRetention(taskID: taskID)
  }

  public func discardForRetention(taskID: TaskID) throws -> PipelinePreflightRetentionRemoval {
    guard !taskID.rawValue.isEmpty, taskID.rawValue.utf8.count <= 256,
      !taskID.rawValue.contains("\0"),
      taskID.rawValue.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw PipelinePreflightStoreError.invalidArgument("taskID") }
    var removal = PipelinePreflightRetentionRemoval.alreadyAbsent
    try updateRecords { records in
      if records.removeValue(forKey: taskID.rawValue) != nil { removal = .removed }
    }
    return removal
  }

  private func updateRecords(
    _ update: (inout [String: PipelinePreflightRecord]) throws -> Void
  ) throws {
    guard let path else {
      var updated = records
      try update(&updated)
      records = updated
      return
    }
    try withExclusiveStoreLock {
      var updated = try Self.load(path: path)
      try update(&updated)
      try persist(updated)
      records = updated
    }
  }

  private func refreshedRecords() throws -> [String: PipelinePreflightRecord] {
    guard let path else { return records }
    return try withExclusiveStoreLock {
      let refreshed = try Self.load(path: path)
      records = refreshed
      return refreshed
    }
  }

  private func persist(_ records: [String: PipelinePreflightRecord]) throws {
    guard let path else { return }
    let payload = PipelinePreflightPayload(
      schemaVersion: 1,
      records: records.values.sorted { $0.key.taskID.rawValue < $1.key.taskID.rawValue }
    )
    do {
      let payloadData = try Self.encode(payload)
      guard payloadData.count <= Self.maximumFileBytes else {
        throw PipelinePreflightStoreError.capacityExceeded
      }
      let envelope = PipelinePreflightEnvelope(
        payload: payloadData,
        sha256: Self.digest(payloadData)
      )
      try Self.writePrivateFile(Self.encode(envelope), path: path)
    } catch let error as PipelinePreflightStoreError {
      throw error
    } catch {
      throw PipelinePreflightStoreError.unavailable
    }
  }

  private func withExclusiveStoreLock<Result>(_ body: () throws -> Result) throws -> Result {
    guard let path else { return try body() }
    Self.processLock.lock()
    defer { Self.processLock.unlock() }
    let location = try PrivateFileLocation(path: path)
    let parent = try location.openParent()
    defer { Darwin.close(parent) }
    let lockName = location.name + ".lock"
    let descriptor = openat(
      parent,
      lockName,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw PipelinePreflightStoreError.unavailable }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
    else { throw PipelinePreflightStoreError.unavailable }
    try Self.acquireExclusiveLock(descriptor)
    defer { Self.releaseLock(descriptor) }
    return try body()
  }

  private static func acquireExclusiveLock(_ descriptor: Int32) throws {
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    for _ in 0..<maximumLockAttempts {
      if fcntl(descriptor, F_SETLK, &lock) == 0 { return }
      guard errno == EACCES || errno == EAGAIN else {
        throw PipelinePreflightStoreError.unavailable
      }
      Thread.sleep(forTimeInterval: Double(lockWaitNanoseconds) / 1_000_000_000)
    }
    throw PipelinePreflightStoreError.unavailable
  }

  private static func releaseLock(_ descriptor: Int32) {
    var lock = flock()
    lock.l_type = Int16(F_UNLCK)
    lock.l_whence = Int16(SEEK_SET)
    _ = fcntl(descriptor, F_SETLK, &lock)
  }

  private static func load(path: String) throws -> [String: PipelinePreflightRecord] {
    guard FileManager.default.fileExists(atPath: path) else { return [:] }
    do {
      let data = try readPrivateFile(path: path, maximumBytes: maximumFileBytes)
      let envelope = try JSONDecoder().decode(PipelinePreflightEnvelope.self, from: data)
      guard digest(envelope.payload) == envelope.sha256 else {
        throw PipelinePreflightStoreError.corruptStore
      }
      let payload = try JSONDecoder().decode(PipelinePreflightPayload.self, from: envelope.payload)
      return try validate(payload)
    } catch let error as PipelinePreflightStoreError {
      throw error
    } catch {
      throw PipelinePreflightStoreError.corruptStore
    }
  }

  private static func validate(_ payload: PipelinePreflightPayload) throws
    -> [String: PipelinePreflightRecord]
  {
    guard payload.schemaVersion == 1, payload.records.count <= maximumRecords else {
      throw PipelinePreflightStoreError.corruptStore
    }
    var result: [String: PipelinePreflightRecord] = [:]
    for record in payload.records {
      try record.validate()
      guard result.updateValue(record, forKey: record.key.taskID.rawValue) == nil else {
        throw PipelinePreflightStoreError.corruptStore
      }
    }
    return result
  }

  private static func validate(
    baseline: GitBaselineEvidence,
    key: PipelinePreflightKey,
    at date: Date
  ) throws {
    let data = try encode(baseline)
    guard data.count <= maximumBaselineBytes else {
      throw PipelinePreflightStoreError.capacityExceeded
    }
    guard date.timeIntervalSince1970.isFinite,
      baseline.projectIdentifier == key.projectID.rawValue,
      baseline.canonicalRootPath.hasPrefix("/"), baseline.rootIdentity != nil
    else { throw PipelinePreflightStoreError.invalidArgument("baseline") }
  }

  private static func readPrivateFile(path: String, maximumBytes: Int) throws -> Data {
    let location = try PrivateFileLocation(path: path)
    let parent = try location.openParent()
    defer { close(parent) }
    let descriptor = openat(parent, location.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PipelinePreflightStoreError.unavailable }
    defer { close(descriptor) }
    try validateFile(descriptor)

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw PipelinePreflightStoreError.unavailable
      }
      guard data.count + count <= maximumBytes else {
        throw PipelinePreflightStoreError.corruptStore
      }
      data.append(buffer, count: count)
    }
    return data
  }

  private static func writePrivateFile(_ data: Data, path: String) throws {
    guard data.count <= maximumFileBytes else {
      throw PipelinePreflightStoreError.capacityExceeded
    }
    let location = try PrivateFileLocation(path: path)
    let parent = try location.openParent()
    defer { close(parent) }
    try validateExistingTarget(parent: parent, name: location.name)
    let temporaryName = ".bridge-preflight-\(UUID().uuidString.lowercased())"
    let descriptor = openat(
      parent,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw PipelinePreflightStoreError.unavailable }
    var renamed = false
    defer {
      close(descriptor)
      if !renamed { unlinkat(parent, temporaryName, 0) }
    }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw PipelinePreflightStoreError.unavailable
    }
    try write(data, to: descriptor)
    guard fsync(descriptor) == 0,
      renameat(parent, temporaryName, parent, location.name) == 0
    else { throw PipelinePreflightStoreError.unavailable }
    renamed = true
    guard fsync(parent) == 0 else { throw PipelinePreflightStoreError.unavailable }
  }

  private static func validateExistingTarget(parent: Int32, name: String) throws {
    let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 {
      guard errno == ENOENT else { throw PipelinePreflightStoreError.unavailable }
      return
    }
    defer { close(descriptor) }
    try validateFile(descriptor)
  }

  private static func validateFile(_ descriptor: Int32) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o777 == S_IRUSR | S_IWUSR
    else { throw PipelinePreflightStoreError.unavailable }
  }

  private static func write(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw PipelinePreflightStoreError.unavailable }
        offset += count
      }
    }
  }

  private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct PrivateFileLocation {
  let parentPath: String
  let name: String

  init(path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard url.path == path, url.path.hasPrefix("/"), !url.lastPathComponent.isEmpty else {
      throw PipelinePreflightStoreError.invalidArgument("path")
    }
    parentPath = url.deletingLastPathComponent().path
    name = url.lastPathComponent
  }

  func openParent() throws -> Int32 {
    let descriptor = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw PipelinePreflightStoreError.unavailable }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o777 == S_IRWXU
    else {
      close(descriptor)
      throw PipelinePreflightStoreError.unavailable
    }
    return descriptor
  }
}

struct PipelinePreflightKey: Codable, Equatable, Sendable {
  let taskID: TaskID
  let projectID: ProjectID
  let threadID: ThreadID
  let generation: UInt64
  let startIntentSequence: Int64

  init(context: TaskPipelinePreStartContext) throws {
    guard context.preparation.turnGeneration > 0, context.startIntentSequence > 0 else {
      throw PipelinePreflightStoreError.invalidArgument("preStart")
    }
    taskID = context.taskID
    projectID = context.submission.projectID
    threadID = context.preparation.threadID
    generation = context.preparation.turnGeneration
    startIntentSequence = context.startIntentSequence
  }

  func validate() throws {
    guard !taskID.rawValue.isEmpty, !projectID.rawValue.isEmpty, !threadID.rawValue.isEmpty,
      generation > 0, startIntentSequence > 0
    else { throw PipelinePreflightStoreError.corruptStore }
  }
}

struct PipelinePreflightRecord: Codable, Equatable, Sendable {
  let key: PipelinePreflightKey
  let baseline: GitBaselineEvidence
  let turnID: TurnID?
  let capturedAt: Date

  func validate() throws {
    try key.validate()
    guard baseline.projectIdentifier == key.projectID.rawValue,
      baseline.canonicalRootPath.hasPrefix("/"), baseline.rootIdentity != nil,
      capturedAt.timeIntervalSince1970.isFinite,
      turnID?.rawValue.isEmpty != true
    else { throw PipelinePreflightStoreError.corruptStore }
  }

  func withTurnID(_ turnID: TurnID) -> PipelinePreflightRecord {
    PipelinePreflightRecord(
      key: key,
      baseline: baseline,
      turnID: turnID,
      capturedAt: capturedAt
    )
  }
}

private struct PipelinePreflightPayload: Codable {
  let schemaVersion: UInt16
  let records: [PipelinePreflightRecord]
}

private struct PipelinePreflightEnvelope: Codable {
  let payload: Data
  let sha256: String
}
