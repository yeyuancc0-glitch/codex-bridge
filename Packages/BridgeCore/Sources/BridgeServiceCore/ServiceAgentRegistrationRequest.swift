import BridgeAgentCore
import Foundation

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
