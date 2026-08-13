import BridgeProjects
import BridgeSecurity
import CryptoKit
import Darwin
import Foundation
import Security

public struct VerificationAuthorizationHandle: Codable, Equatable, Hashable, Sendable {
  public let nonce: String

  init(nonce: String) throws {
    guard Self.isValid(nonce) else {
      throw VerificationAuthorizationError.invalidArgument("nonce")
    }
    self.nonce = nonce
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(nonce: container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(nonce)
  }

  private static func isValid(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy(Set("0123456789abcdef").contains)
  }
}

public enum VerificationAuthorizationError: Error, Equatable, Sendable {
  case invalidArgument(String)
  case storeUnavailable
  case corruptStore
  case capacityExceeded
  case randomGenerationFailed
  case unknownHandle
  case alreadyConsumed
  case expired
  case bindingMismatch
}

package protocol VerificationAuthorizationClock: Sendable {
  func now() -> Date
}

package struct SystemVerificationAuthorizationClock: VerificationAuthorizationClock {
  package init() {}

  package func now() -> Date { Date() }
}

public actor VerificationAuthorizationStore {
  public static let maximumLifetime: TimeInterval = 3_600
  public static let maximumRecords = 4_096
  private static let processLock = NSLock()
  private static let lockWaitNanoseconds: UInt64 = 10_000_000
  private static let maximumLockAttempts = 500

  private let path: String
  private let clock: any VerificationAuthorizationClock

  public init(path: String) throws {
    try self.init(path: path, clock: SystemVerificationAuthorizationClock())
  }

  package init(
    path: String,
    clock: any VerificationAuthorizationClock
  ) throws {
    guard !path.isEmpty, path.utf8.count <= 16_384, !path.contains("\0") else {
      throw VerificationAuthorizationError.invalidArgument("path")
    }
    self.path = path
    self.clock = clock
    _ = try Self.load(path: path)
  }

  @discardableResult
  public func issue(
    taskID: String,
    project: RegisteredProject,
    workingDirectory: RegisteredRoot,
    command selection: VerificationCommandSelection,
    generation: Int64,
    validFor lifetime: TimeInterval = 300
  ) throws -> VerificationAuthorizationHandle {
    try Self.validateTaskID(taskID)
    guard generation > 0 else {
      throw VerificationAuthorizationError.invalidArgument("generation")
    }
    try Self.validateMembership(workingDirectory, project: project)
    let command = try VerificationCommandResolver().resolve(
      selection,
      commands: project.verificationCommands
    )
    return try withExclusiveStoreLock {
      let issuedAt = clock.now()
      try Self.validateTimes(issuedAt: issuedAt, lifetime: lifetime)
      let records = try Self.load(path: path)
      let retained = records.filter { $0.value.expiresAt > issuedAt.timeIntervalSince1970 }
      guard retained.count < Self.maximumRecords else {
        throw VerificationAuthorizationError.capacityExceeded
      }

      let nonce = try makeUniqueNonce(in: retained)
      let handle = try VerificationAuthorizationHandle(nonce: nonce)
      let nonceDigest = Self.digest(Data(nonce.utf8))
      let record = AuthorizationRecord(
        nonceDigest: nonceDigest,
        taskID: taskID,
        projectID: project.id.rawValue,
        commandID: command.identifier.rawValue,
        rootDevice: workingDirectory.identity.device,
        rootInode: workingDirectory.identity.inode,
        generation: generation,
        issuedAt: issuedAt.timeIntervalSince1970,
        expiresAt: issuedAt.addingTimeInterval(lifetime).timeIntervalSince1970,
        consumedAt: nil
      )
      var updated = retained
      updated[nonceDigest] = record
      try persist(updated)
      return handle
    }
  }

  func consume(
    _ handle: VerificationAuthorizationHandle,
    taskID: String,
    project: RegisteredProject,
    workingDirectory: RegisteredRoot,
    command: ResolvedVerificationCommand,
    generation: Int64
  ) throws {
    try Self.validateTaskID(taskID)
    guard generation > 0 else {
      throw VerificationAuthorizationError.invalidArgument("consume")
    }
    try withExclusiveStoreLock {
      let now = clock.now()
      guard now.timeIntervalSince1970.isFinite else {
        throw VerificationAuthorizationError.invalidArgument("consume")
      }
      let records = try Self.load(path: path)
      let nonceDigest = Self.digest(Data(handle.nonce.utf8))
      guard let record = records[nonceDigest] else {
        throw VerificationAuthorizationError.unknownHandle
      }
      guard record.consumedAt == nil else {
        throw VerificationAuthorizationError.alreadyConsumed
      }
      guard now.timeIntervalSince1970 >= record.issuedAt,
        now.timeIntervalSince1970 < record.expiresAt
      else {
        throw VerificationAuthorizationError.expired
      }
      guard
        record.matches(
          taskID: taskID,
          projectID: project.id.rawValue,
          commandID: command.identifier.rawValue,
          root: workingDirectory,
          generation: generation
        )
      else { throw VerificationAuthorizationError.bindingMismatch }

      var updated = records
      updated[nonceDigest] = record.consumed(at: now.timeIntervalSince1970)
      try persist(updated)
    }
  }

  private func makeUniqueNonce(in records: [String: AuthorizationRecord]) throws -> String {
    for _ in 0..<4 {
      let nonce = try Self.randomNonce()
      if records[Self.digest(Data(nonce.utf8))] == nil { return nonce }
    }
    throw VerificationAuthorizationError.randomGenerationFailed
  }

  private func withExclusiveStoreLock<Result>(_ body: () throws -> Result) throws -> Result {
    Self.processLock.lock()
    defer { Self.processLock.unlock() }
    let lockPath = path + ".lock"
    let descriptor = lockPath.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { throw VerificationAuthorizationError.storeUnavailable }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_uid == geteuid(),
      fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
    else { throw VerificationAuthorizationError.storeUnavailable }
    var exclusiveLock = flock()
    exclusiveLock.l_type = Int16(F_WRLCK)
    exclusiveLock.l_whence = Int16(SEEK_SET)
    var acquired = false
    for _ in 0..<Self.maximumLockAttempts {
      if fcntl(descriptor, F_SETLK, &exclusiveLock) == 0 {
        acquired = true
        break
      }
      guard errno == EACCES || errno == EAGAIN else {
        throw VerificationAuthorizationError.storeUnavailable
      }
      Thread.sleep(forTimeInterval: Double(Self.lockWaitNanoseconds) / 1_000_000_000)
    }
    guard acquired else { throw VerificationAuthorizationError.storeUnavailable }
    defer {
      var unlock = flock()
      unlock.l_type = Int16(F_UNLCK)
      unlock.l_whence = Int16(SEEK_SET)
      _ = fcntl(descriptor, F_SETLK, &unlock)
    }
    return try body()
  }

  private func persist(_ records: [String: AuthorizationRecord]) throws {
    let payload = AuthorizationPayload(
      schemaVersion: 1,
      records: records.values.sorted { $0.nonceDigest < $1.nonceDigest }
    )
    do {
      let payloadData = try Self.encode(payload)
      let envelope = AuthorizationEnvelope(
        payload: payloadData,
        sha256: Self.digest(payloadData)
      )
      let envelopeData = try Self.encode(envelope)
      try Self.validateDestination(path: path)
      try envelopeData.write(to: URL(fileURLWithPath: path), options: .atomic)
      guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
        throw VerificationAuthorizationError.storeUnavailable
      }
    } catch let error as VerificationAuthorizationError {
      throw error
    } catch {
      throw VerificationAuthorizationError.storeUnavailable
    }
  }

  private static func load(path: String) throws -> [String: AuthorizationRecord] {
    guard FileManager.default.fileExists(atPath: path) else { return [:] }
    do {
      try validateDestination(path: path)
      let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
      guard data.count <= 4 * 1_024 * 1_024 else {
        throw VerificationAuthorizationError.corruptStore
      }
      let envelope = try JSONDecoder().decode(AuthorizationEnvelope.self, from: data)
      guard digest(envelope.payload) == envelope.sha256 else {
        throw VerificationAuthorizationError.corruptStore
      }
      let payload = try JSONDecoder().decode(AuthorizationPayload.self, from: envelope.payload)
      return try validate(payload)
    } catch let error as VerificationAuthorizationError {
      throw error
    } catch {
      throw VerificationAuthorizationError.corruptStore
    }
  }

  private static func validate(_ payload: AuthorizationPayload) throws
    -> [String: AuthorizationRecord]
  {
    guard payload.schemaVersion == 1, payload.records.count <= maximumRecords else {
      throw VerificationAuthorizationError.corruptStore
    }
    var result: [String: AuthorizationRecord] = [:]
    for record in payload.records {
      try record.validate()
      guard result.updateValue(record, forKey: record.nonceDigest) == nil else {
        throw VerificationAuthorizationError.corruptStore
      }
    }
    return result
  }

  private static func validateDestination(path: String) throws {
    var metadata = stat()
    let status = path.withCString { lstat($0, &metadata) }
    if status != 0 {
      guard errno == ENOENT else { throw VerificationAuthorizationError.storeUnavailable }
      return
    }
    guard metadata.st_uid == geteuid(), (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_mode & 0o777 == 0o600
    else {
      throw VerificationAuthorizationError.storeUnavailable
    }
  }

  private static func validateMembership(
    _ workingDirectory: RegisteredRoot,
    project: RegisteredProject
  ) throws {
    guard ([project.primaryRoot] + project.worktreeRoots).contains(workingDirectory) else {
      throw VerificationRunnerError.workingDirectoryNotRegistered
    }
  }

  private static func validateTaskID(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 256, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw VerificationAuthorizationError.invalidArgument("taskID") }
  }

  private static func validateTimes(issuedAt: Date, lifetime: TimeInterval) throws {
    guard issuedAt.timeIntervalSince1970.isFinite, lifetime.isFinite, lifetime > 0,
      lifetime <= maximumLifetime
    else { throw VerificationAuthorizationError.invalidArgument("lifetime") }
  }

  private static func randomNonce() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw VerificationAuthorizationError.randomGenerationFailed
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
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

private struct AuthorizationPayload: Codable {
  let schemaVersion: UInt16
  let records: [AuthorizationRecord]
}

private struct AuthorizationEnvelope: Codable {
  let payload: Data
  let sha256: String
}

private struct AuthorizationRecord: Codable {
  let nonceDigest: String
  let taskID: String
  let projectID: String
  let commandID: String
  let rootDevice: UInt64
  let rootInode: UInt64
  let generation: Int64
  let issuedAt: TimeInterval
  let expiresAt: TimeInterval
  let consumedAt: TimeInterval?

  func validate() throws {
    guard Self.isLowercaseSHA256(nonceDigest),
      !taskID.isEmpty, taskID.utf8.count <= 256,
      !projectID.isEmpty, projectID.utf8.count <= 256,
      VerificationCommandIdentifier(rawValue: commandID) != nil,
      generation > 0, issuedAt.isFinite, expiresAt.isFinite,
      expiresAt > issuedAt, expiresAt - issuedAt <= VerificationAuthorizationStore.maximumLifetime,
      consumedAt?.isFinite != false,
      consumedAt.map({ $0 >= issuedAt && $0 < expiresAt }) ?? true
    else { throw VerificationAuthorizationError.corruptStore }
  }

  func matches(
    taskID: String,
    projectID: String,
    commandID: String,
    root: RegisteredRoot,
    generation: Int64
  ) -> Bool {
    self.taskID == taskID && self.projectID == projectID && self.commandID == commandID
      && rootDevice == root.identity.device && rootInode == root.identity.inode
      && self.generation == generation
  }

  func consumed(at timestamp: TimeInterval) -> AuthorizationRecord {
    AuthorizationRecord(
      nonceDigest: nonceDigest,
      taskID: taskID,
      projectID: projectID,
      commandID: commandID,
      rootDevice: rootDevice,
      rootInode: rootInode,
      generation: generation,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      consumedAt: timestamp
    )
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy(Set("0123456789abcdef").contains)
  }
}
