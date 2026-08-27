import BridgeAgentCore
import CryptoKit
import Darwin
import Foundation

public enum ServiceAgentInstallationAvailability: String, Codable, CaseIterable, Sendable {
  case available
  case unavailable
  case needsReview = "needs_review"
}

public typealias ServiceAgentInstallationArtifactRole = AgentInstallationArtifactRole

public struct ServiceAgentFileIdentity: Codable, Equatable, Sendable {
  public static let maximumFileBytes: UInt64 = 1_073_741_824
  public static let maximumConfigurationBytes: UInt64 = 256 * 1_024

  public let canonicalPath: String
  public let device: UInt64
  public let inode: UInt64
  public let fileSize: UInt64
  public let modificationTimeNanoseconds: Int64
  public let sha256: String

  public init(
    canonicalPath: String,
    device: UInt64,
    inode: UInt64,
    fileSize: UInt64,
    modificationTimeNanoseconds: Int64,
    sha256: String
  ) throws {
    guard canonicalPath.hasPrefix("/"),
      canonicalPath.utf8.count <= 16 * 1_024,
      !canonicalPath.contains("\0"),
      canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil,
      inode > 0,
      fileSize > 0,
      fileSize <= Self.maximumFileBytes,
      modificationTimeNanoseconds >= 0,
      Self.isLowercaseSHA256(sha256)
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
    self.sha256 = sha256
  }

  public init(capturing path: String, requiresExecutable: Bool = false) throws {
    try Self.validate(path: path)
    let canonicalPath = URL(fileURLWithPath: path)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    let descriptor = Darwin.open(canonicalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactPath")
    }
    defer { Darwin.close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
    try Self.validateFile(before, requiresExecutable: requiresExecutable)
    let digest = try Self.digest(descriptor)

    var after = stat()
    guard fstat(descriptor, &after) == 0, Self.sameSnapshot(before, after) else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactChanged")
    }
    let modificationTime = try Self.modificationTimeNanoseconds(after)
    try self.init(
      canonicalPath: canonicalPath,
      device: UInt64(after.st_dev),
      inode: UInt64(after.st_ino),
      fileSize: UInt64(after.st_size),
      modificationTimeNanoseconds: modificationTime,
      sha256: digest
    )
  }

  public init(capturing path: String, role: ServiceAgentInstallationArtifactRole) throws {
    try self.init(capturing: path, requiresExecutable: role.requiresExecutable)
  }

  private static func validate(path: String) throws {
    guard path.hasPrefix("/"),
      path.utf8.count <= 16 * 1_024,
      !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactPath")
    }
  }

  private static func validateFile(_ metadata: stat, requiresExecutable: Bool) throws {
    let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
    let hasExecutableBit = metadata.st_mode & executableBits != 0
    guard metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid() || metadata.st_uid == 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0,
      !requiresExecutable || hasExecutableBit,
      metadata.st_size > 0,
      UInt64(metadata.st_size) <= Self.maximumFileBytes
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
  }

  private static func digest(_ descriptor: Int32) throws -> String {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
      }
      hasher.update(data: Data(buffer.prefix(count)))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func sameSnapshot(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev
      && first.st_ino == second.st_ino
      && first.st_size == second.st_size
      && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
      && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
  }

  private static func modificationTimeNanoseconds(_ metadata: stat) throws -> Int64 {
    let seconds = Int64(metadata.st_mtimespec.tv_sec)
    let nanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
    guard seconds >= 0, (0..<1_000_000_000).contains(nanoseconds) else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
    let (base, multipliedOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let (result, addedOverflow) = base.addingReportingOverflow(nanoseconds)
    guard !multipliedOverflow, !addedOverflow else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactIdentity")
    }
    return result
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}

public struct ServiceAgentInstallationArtifactRequest: Codable, Equatable, Sendable {
  public let role: ServiceAgentInstallationArtifactRole
  public let path: String

  public init(role: ServiceAgentInstallationArtifactRole, path: String) throws {
    try ServiceValidation.text(
      path,
      field: "agentRegistration.artifactPath",
      maximumBytes: 16 * 1_024
    )
    guard path.hasPrefix("/"),
      !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("agentRegistration.artifactPath")
    }
    self.role = role
    self.path = path
  }
}

public typealias ServiceAgentArtifactRequest = ServiceAgentInstallationArtifactRequest

public struct ServiceAgentInstallationArtifact: Codable, Equatable, Sendable {
  public static let maximumCount = 16

  public let role: ServiceAgentInstallationArtifactRole
  public let identity: ServiceAgentFileIdentity
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    role: ServiceAgentInstallationArtifactRole,
    identity: ServiceAgentFileIdentity,
    createdAt: Date,
    updatedAt: Date
  ) throws {
    try ServiceValidation.date(createdAt, field: "agentInstallation.artifact.createdAt")
    try ServiceValidation.date(updatedAt, field: "agentInstallation.artifact.updatedAt")
    guard updatedAt >= createdAt else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifact.timestamps")
    }
    self.role = role
    self.identity = identity
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public init(
    capturing request: ServiceAgentInstallationArtifactRequest,
    at date: Date
  ) throws {
    let identity = try ServiceAgentFileIdentity(capturing: request.path, role: request.role)
    guard
      request.role != .launchConfiguration
        || identity.fileSize <= ServiceAgentFileIdentity.maximumConfigurationBytes
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifactSize")
    }
    try self.init(
      role: request.role,
      identity: identity,
      createdAt: date,
      updatedAt: date
    )
  }

  public var canonicalPath: String { identity.canonicalPath }
  public var path: String { identity.canonicalPath }
}

public struct ServiceAgentExecutableIdentity: Codable, Equatable, Sendable {
  public static let maximumExecutableBytes: UInt64 = 1_073_741_824

  public let canonicalPath: String
  public let device: UInt64
  public let inode: UInt64
  public let fileSize: UInt64
  public let modificationTimeNanoseconds: Int64
  public let sha256: String

  public init(
    canonicalPath: String,
    device: UInt64,
    inode: UInt64,
    fileSize: UInt64,
    modificationTimeNanoseconds: Int64,
    sha256: String
  ) throws {
    guard canonicalPath.hasPrefix("/"),
      canonicalPath.utf8.count <= 16 * 1_024,
      !canonicalPath.contains("\0"),
      canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil,
      inode > 0,
      fileSize > 0,
      fileSize <= Self.maximumExecutableBytes,
      modificationTimeNanoseconds >= 0,
      Self.isLowercaseSHA256(sha256)
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
    }
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
    self.sha256 = sha256
  }

  public init(capturing executablePath: String) throws {
    guard executablePath.hasPrefix("/"),
      executablePath.utf8.count <= 16 * 1_024,
      !executablePath.contains("\0"),
      executablePath.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executablePath")
    }
    let canonicalPath = URL(fileURLWithPath: executablePath)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    let descriptor = Darwin.open(canonicalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executablePath")
    }
    defer { Darwin.close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
    }
    try Self.validateExecutable(before)
    let digest = try Self.digest(descriptor)

    var after = stat()
    guard fstat(descriptor, &after) == 0,
      Self.sameFileSnapshot(before, after)
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableChanged")
    }
    let modificationTime = try Self.modificationTimeNanoseconds(after)
    try self.init(
      canonicalPath: canonicalPath,
      device: UInt64(after.st_dev),
      inode: UInt64(after.st_ino),
      fileSize: UInt64(after.st_size),
      modificationTimeNanoseconds: modificationTime,
      sha256: digest
    )
  }

  private static func validateExecutable(_ metadata: stat) throws {
    let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
    guard metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid() || metadata.st_uid == 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0,
      metadata.st_mode & executableBits != 0,
      metadata.st_size > 0,
      UInt64(metadata.st_size) <= maximumExecutableBytes
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
    }
  }

  private static func digest(_ descriptor: Int32) throws -> String {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
      }
      hasher.update(data: Data(buffer.prefix(count)))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func sameFileSnapshot(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev
      && first.st_ino == second.st_ino
      && first.st_size == second.st_size
      && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
      && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
  }

  private static func modificationTimeNanoseconds(_ metadata: stat) throws -> Int64 {
    let seconds = Int64(metadata.st_mtimespec.tv_sec)
    let nanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
    guard seconds >= 0, (0..<1_000_000_000).contains(nanoseconds) else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
    }
    let (base, multipliedOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let (result, addedOverflow) = base.addingReportingOverflow(nanoseconds)
    guard !multipliedOverflow, !addedOverflow else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executableIdentity")
    }
    return result
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}

public struct ServiceAgentInstallationRecord: Codable, Equatable, Sendable {
  public let id: AgentInstallationID
  public let providerID: AgentProviderID
  public let displayName: String
  public let executablePath: String
  public let executableIdentity: ServiceAgentExecutableIdentity
  public let version: String?
  public let protocolRevision: String?
  public let adapterRevision: Int
  public let trustProfile: AgentTrustProfile
  public let securityProfileID: AgentProfileID?
  public let isEnabled: Bool
  public let availability: ServiceAgentInstallationAvailability
  public let capabilities: AgentCapabilitySnapshot
  public let artifacts: [ServiceAgentInstallationArtifact]
  public let lastProbeError: String?
  public let lastProbedAt: Date?
  public let createdAt: Date
  public let updatedAt: Date

  public var isSelectable: Bool {
    isEnabled && availability == .available
  }

  public init(
    id: AgentInstallationID,
    providerID: AgentProviderID,
    displayName: String,
    executablePath: String,
    executableIdentity: ServiceAgentExecutableIdentity,
    version: String?,
    protocolRevision: String?,
    adapterRevision: Int,
    trustProfile: AgentTrustProfile,
    securityProfileID: AgentProfileID?,
    isEnabled: Bool,
    availability: ServiceAgentInstallationAvailability,
    capabilities: AgentCapabilitySnapshot,
    artifacts: [ServiceAgentInstallationArtifact] = [],
    lastProbeError: String? = nil,
    lastProbedAt: Date? = nil,
    createdAt: Date,
    updatedAt: Date
  ) throws {
    try ServiceValidation.identifier(
      id.rawValue,
      field: "agentInstallation.id",
      maximumBytes: 256
    )
    try ServiceValidation.identifier(
      providerID.rawValue,
      field: "agentInstallation.providerID",
      maximumBytes: 128
    )
    try ServiceValidation.text(
      displayName,
      field: "agentInstallation.displayName",
      maximumBytes: 256
    )
    guard executablePath.hasPrefix("/"),
      executablePath.utf8.count <= 16 * 1_024,
      !executablePath.contains("\0"),
      executablePath.rangeOfCharacter(from: .controlCharacters) == nil,
      adapterRevision > 0
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.executablePath")
    }
    if let version {
      try ServiceValidation.identifier(
        version,
        field: "agentInstallation.version",
        maximumBytes: 256
      )
    }
    if let protocolRevision {
      try ServiceValidation.identifier(
        protocolRevision,
        field: "agentInstallation.protocolRevision",
        maximumBytes: 128
      )
    }
    if let securityProfileID {
      try ServiceValidation.identifier(
        securityProfileID.rawValue,
        field: "agentInstallation.securityProfileID",
        maximumBytes: 256
      )
    }
    try ServiceValidation.optionalText(
      lastProbeError,
      field: "agentInstallation.lastProbeError",
      maximumBytes: 4 * 1_024
    )
    try ServiceValidation.date(createdAt, field: "agentInstallation.createdAt")
    try ServiceValidation.date(updatedAt, field: "agentInstallation.updatedAt")
    if let lastProbedAt {
      try ServiceValidation.date(lastProbedAt, field: "agentInstallation.lastProbedAt")
    }
    guard updatedAt >= createdAt,
      lastProbedAt.map({ $0 >= createdAt && $0 <= updatedAt }) ?? true
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.timestamps")
    }
    if availability == .available {
      guard version != nil, lastProbedAt != nil, lastProbeError == nil else {
        throw ServiceStoreError.invalidArgument("agentInstallation.availableState")
      }
    } else {
      guard capabilities == .empty else {
        throw ServiceStoreError.invalidArgument("agentInstallation.capabilities")
      }
    }
    guard artifacts.count <= ServiceAgentInstallationArtifact.maximumCount,
      Set(artifacts.map(\.role)).count == artifacts.count
    else {
      throw ServiceStoreError.invalidArgument("agentInstallation.artifacts")
    }
    self.id = id
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
    self.executableIdentity = executableIdentity
    self.version = version
    self.protocolRevision = protocolRevision
    self.adapterRevision = adapterRevision
    self.trustProfile = trustProfile
    self.securityProfileID = securityProfileID
    self.isEnabled = isEnabled
    self.availability = availability
    self.capabilities = capabilities
    self.artifacts = artifacts.sorted { $0.role.rawValue < $1.role.rawValue }
    self.lastProbeError = lastProbeError
    self.lastProbedAt = lastProbedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case providerID
    case displayName
    case executablePath
    case executableIdentity
    case version
    case protocolRevision
    case adapterRevision
    case trustProfile
    case securityProfileID
    case isEnabled
    case availability
    case capabilities
    case artifacts
    case lastProbeError
    case lastProbedAt
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(AgentInstallationID.self, forKey: .id),
      providerID: container.decode(AgentProviderID.self, forKey: .providerID),
      displayName: container.decode(String.self, forKey: .displayName),
      executablePath: container.decode(String.self, forKey: .executablePath),
      executableIdentity: container.decode(
        ServiceAgentExecutableIdentity.self,
        forKey: .executableIdentity
      ),
      version: container.decodeIfPresent(String.self, forKey: .version),
      protocolRevision: container.decodeIfPresent(String.self, forKey: .protocolRevision),
      adapterRevision: container.decode(Int.self, forKey: .adapterRevision),
      trustProfile: container.decode(AgentTrustProfile.self, forKey: .trustProfile),
      securityProfileID: container.decodeIfPresent(AgentProfileID.self, forKey: .securityProfileID),
      isEnabled: container.decode(Bool.self, forKey: .isEnabled),
      availability: container.decode(
        ServiceAgentInstallationAvailability.self,
        forKey: .availability
      ),
      capabilities: container.decode(AgentCapabilitySnapshot.self, forKey: .capabilities),
      artifacts: container.decodeIfPresent(
        [ServiceAgentInstallationArtifact].self,
        forKey: .artifacts
      ) ?? [],
      lastProbeError: container.decodeIfPresent(String.self, forKey: .lastProbeError),
      lastProbedAt: container.decodeIfPresent(Date.self, forKey: .lastProbedAt),
      createdAt: container.decode(Date.self, forKey: .createdAt),
      updatedAt: container.decode(Date.self, forKey: .updatedAt)
    )
  }

  public func agentInstallation() throws -> AgentInstallation {
    try AgentInstallation(
      id: id,
      providerID: providerID,
      executablePath: executableIdentity.canonicalPath,
      version: version,
      protocolRevision: protocolRevision,
      artifacts: artifacts.map { artifact in
        AgentInstallationArtifact(
          role: artifact.role,
          canonicalPath: artifact.identity.canonicalPath,
          device: artifact.identity.device,
          inode: artifact.identity.inode,
          fileSize: artifact.identity.fileSize,
          modificationTimeNanoseconds: artifact.identity.modificationTimeNanoseconds,
          sha256: artifact.identity.sha256
        )
      }
    )
  }

  public func replacingEnabled(_ enabled: Bool, updatedAt: Date) throws
    -> ServiceAgentInstallationRecord
  {
    try ServiceAgentInstallationRecord(
      id: id,
      providerID: providerID,
      displayName: displayName,
      executablePath: executablePath,
      executableIdentity: executableIdentity,
      version: version,
      protocolRevision: protocolRevision,
      adapterRevision: adapterRevision,
      trustProfile: trustProfile,
      securityProfileID: securityProfileID,
      isEnabled: enabled,
      availability: availability,
      capabilities: capabilities,
      artifacts: artifacts,
      lastProbeError: lastProbeError,
      lastProbedAt: lastProbedAt,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

public struct ServiceAgentRegistrationRequest: Equatable, Sendable {
  public let providerID: AgentProviderID
  public let displayName: String
  public let executablePath: String
  public let trustProfile: AgentTrustProfile
  public let securityProfileID: AgentProfileID?
  public let enableOnSuccess: Bool
  public let projectRoot: String?
  public let configurationPath: String?
  public let artifacts: [ServiceAgentInstallationArtifactRequest]

  public init(
    providerID: AgentProviderID,
    displayName: String,
    executablePath: String,
    trustProfile: AgentTrustProfile,
    securityProfileID: AgentProfileID? = nil,
    enableOnSuccess: Bool = false,
    projectRoot: String? = nil,
    configurationPath: String? = nil,
    artifacts: [ServiceAgentInstallationArtifactRequest] = []
  ) throws {
    try ServiceValidation.identifier(
      providerID.rawValue,
      field: "agentRegistration.providerID",
      maximumBytes: 128
    )
    try ServiceValidation.text(
      displayName,
      field: "agentRegistration.displayName",
      maximumBytes: 256
    )
    guard executablePath.hasPrefix("/"),
      executablePath.utf8.count <= 16 * 1_024,
      !executablePath.contains("\0")
    else {
      throw ServiceStoreError.invalidArgument("agentRegistration.executablePath")
    }
    if let securityProfileID {
      try ServiceValidation.identifier(
        securityProfileID.rawValue,
        field: "agentRegistration.securityProfileID",
        maximumBytes: 256
      )
    }
    if let projectRoot {
      guard projectRoot.hasPrefix("/"),
        projectRoot.utf8.count <= 16 * 1_024,
        !projectRoot.contains("\0")
      else {
        throw ServiceStoreError.invalidArgument("agentRegistration.projectRoot")
      }
    }
    if let configurationPath {
      guard configurationPath.hasPrefix("/"),
        configurationPath.utf8.count <= 16 * 1_024,
        !configurationPath.contains("\0"),
        configurationPath.rangeOfCharacter(from: .controlCharacters) == nil
      else {
        throw ServiceStoreError.invalidArgument("agentRegistration.configurationPath")
      }
    }
    guard artifacts.count <= ServiceAgentInstallationArtifact.maximumCount,
      Set(artifacts.map(\.role)).count == artifacts.count,
      !artifacts.contains(where: { $0.role == .launchConfiguration && configurationPath != nil })
    else {
      throw ServiceStoreError.invalidArgument("agentRegistration.artifacts")
    }
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
    self.trustProfile = trustProfile
    self.securityProfileID = securityProfileID
    self.enableOnSuccess = enableOnSuccess
    self.projectRoot = projectRoot
    self.configurationPath = configurationPath
    self.artifacts = artifacts
  }

  public var artifactRequests: [ServiceAgentInstallationArtifactRequest] {
    var result = artifacts
    if let configurationPath {
      if let request = try? ServiceAgentInstallationArtifactRequest(
        role: .launchConfiguration,
        path: configurationPath
      ) {
        result.insert(request, at: 0)
      }
    }
    return result
  }
}
