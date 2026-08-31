import Foundation

public struct ServiceAgentInstallationArtifactRequest: Codable, Equatable, Sendable {
  public let role: ServiceAgentInstallationArtifactRole
  public let path: String

  public init(role: ServiceAgentInstallationArtifactRole, path: String) throws {
    try ServiceValidation.text(
      path,
      field: "agentRegistration.artifactPath",
      maximumBytes: 16 * 1_024
    )
    try ServiceValidation.absolutePath(path, field: "agentRegistration.artifactPath")
    guard path.rangeOfCharacter(from: .controlCharacters) == nil else {
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
