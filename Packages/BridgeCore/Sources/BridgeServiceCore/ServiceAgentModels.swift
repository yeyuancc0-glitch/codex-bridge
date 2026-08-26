import BridgeAgentCore
import CryptoKit
import Darwin
import Foundation

public enum ServiceAgentInstallationAvailability: String, Codable, CaseIterable, Sendable {
  case available
  case unavailable
  case needsReview = "needs_review"
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
    self.lastProbeError = lastProbeError
    self.lastProbedAt = lastProbedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public func agentInstallation() throws -> AgentInstallation {
    try AgentInstallation(
      id: id,
      providerID: providerID,
      executablePath: executableIdentity.canonicalPath,
      version: version,
      protocolRevision: protocolRevision
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

  public init(
    providerID: AgentProviderID,
    displayName: String,
    executablePath: String,
    trustProfile: AgentTrustProfile,
    securityProfileID: AgentProfileID? = nil,
    enableOnSuccess: Bool = false,
    projectRoot: String? = nil
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
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
    self.trustProfile = trustProfile
    self.securityProfileID = securityProfileID
    self.enableOnSuccess = enableOnSuccess
    self.projectRoot = projectRoot
  }
}
