import BridgePresentation
import Darwin
import Foundation

enum DesktopOnboardingStoreError: LocalizedError, Equatable, Sendable {
  case corruptState
  case insecureStateFile
  case systemFailure(Int32)

  var errorDescription: String? {
    switch self {
    case .corruptState:
      "首次设置状态已损坏；Bridge 不会跳过安全引导。"
    case .insecureStateFile:
      "首次设置状态文件的权限或类型不安全。"
    case .systemFailure:
      "无法安全读写首次设置状态。"
    }
  }
}

struct DesktopOnboardingRecord: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  var currentStep: OnboardingStep
  var completed: Bool
  let profileID: UUID
  var connectionMode: OnboardingConnectionMode?
  var tunnelID: String?
  var manualHTTPSEndpoint: String?
  var projectID: String?
  var projectName: String?
  var writeDefault: OnboardingPermissionDefault
  var networkDefault: OnboardingPermissionDefault
  var securityDefaultsSaved: Bool
  var connectionTestSucceeded: Bool

  static func fresh() -> DesktopOnboardingRecord {
    DesktopOnboardingRecord(
      schemaVersion: schemaVersion,
      currentStep: .welcome,
      completed: false,
      profileID: UUID(),
      connectionMode: nil,
      tunnelID: nil,
      manualHTTPSEndpoint: nil,
      projectID: nil,
      projectName: nil,
      writeDefault: .localApproval,
      networkDefault: .denied,
      securityDefaultsSaved: false,
      connectionTestSucceeded: false
    )
  }

  func validate() throws {
    guard schemaVersion == Self.schemaVersion else {
      throw DesktopOnboardingStoreError.corruptState
    }
    let values = [tunnelID, manualHTTPSEndpoint, projectID, projectName].compactMap { $0 }
    guard values.allSatisfy(Self.isSafeString) else {
      throw DesktopOnboardingStoreError.corruptState
    }
    guard !completed || currentStep == .completion else {
      throw DesktopOnboardingStoreError.corruptState
    }
    guard !securityDefaultsSaved || projectID != nil else {
      throw DesktopOnboardingStoreError.corruptState
    }
    guard
      !connectionTestSucceeded
        || (connectionMode != nil && projectID != nil && securityDefaultsSaved)
    else {
      throw DesktopOnboardingStoreError.corruptState
    }
    guard !completed || connectionTestSucceeded else {
      throw DesktopOnboardingStoreError.corruptState
    }
    if currentStep.rawValue >= OnboardingStep.connectionConfiguration.rawValue,
      connectionMode == nil
    {
      throw DesktopOnboardingStoreError.corruptState
    }
    if currentStep.rawValue >= OnboardingStep.securityDefaults.rawValue, projectID == nil {
      throw DesktopOnboardingStoreError.corruptState
    }
  }

  private static func isSafeString(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4_096 && !value.contains("\0")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }
}

struct DesktopOnboardingStore: Sendable {
  private static let fileName = "onboarding.json"
  private static let maximumBytes = 32 * 1_024

  let directoryURL: URL

  func load() throws -> DesktopOnboardingRecord {
    let directory = try openDirectory()
    defer { close(directory) }
    let descriptor = openat(directory, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0, errno == ENOENT { return .fresh() }
    guard descriptor >= 0 else {
      if errno == ELOOP { throw DesktopOnboardingStoreError.insecureStateFile }
      throw DesktopOnboardingStoreError.systemFailure(errno)
    }
    defer { close(descriptor) }
    try validateFile(descriptor)
    let data = try read(descriptor)
    let record: DesktopOnboardingRecord
    do {
      record = try JSONDecoder().decode(DesktopOnboardingRecord.self, from: data)
    } catch {
      throw DesktopOnboardingStoreError.corruptState
    }
    try record.validate()
    return record
  }

  func save(_ record: DesktopOnboardingRecord) throws {
    try record.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(record)
    guard !data.isEmpty, data.count <= Self.maximumBytes else {
      throw DesktopOnboardingStoreError.corruptState
    }
    let directory = try openDirectory()
    defer { close(directory) }
    let temporaryName = ".onboarding.\(UUID().uuidString.lowercased()).tmp"
    let descriptor = openat(
      directory,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw DesktopOnboardingStoreError.systemFailure(errno) }
    var keepTemporary = true
    defer {
      close(descriptor)
      if keepTemporary { unlinkat(directory, temporaryName, 0) }
    }
    try write(data, to: descriptor)
    guard fsync(descriptor) == 0 else {
      throw DesktopOnboardingStoreError.systemFailure(errno)
    }
    guard renameat(directory, temporaryName, directory, Self.fileName) == 0 else {
      throw DesktopOnboardingStoreError.systemFailure(errno)
    }
    keepTemporary = false
    guard fsync(directory) == 0 else {
      throw DesktopOnboardingStoreError.systemFailure(errno)
    }
  }

  private func openDirectory() throws -> Int32 {
    let descriptor = open(
      directoryURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw DesktopOnboardingStoreError.systemFailure(errno) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      close(descriptor)
      throw DesktopOnboardingStoreError.systemFailure(errno)
    }
    guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o777 == 0o700
    else {
      close(descriptor)
      throw DesktopOnboardingStoreError.insecureStateFile
    }
    return descriptor
  }

  private func validateFile(_ descriptor: Int32) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw DesktopOnboardingStoreError.systemFailure(errno)
    }
    guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_mode & 0o777 == 0o600,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumBytes
    else {
      throw DesktopOnboardingStoreError.insecureStateFile
    }
  }

  private func read(_ descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { return result }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw DesktopOnboardingStoreError.systemFailure(errno) }
      guard result.count + count <= Self.maximumBytes else {
        throw DesktopOnboardingStoreError.corruptState
      }
      result.append(buffer, count: count)
    }
  }

  private func write(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        throw DesktopOnboardingStoreError.corruptState
      }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw DesktopOnboardingStoreError.systemFailure(errno) }
        offset += count
      }
    }
  }
}
