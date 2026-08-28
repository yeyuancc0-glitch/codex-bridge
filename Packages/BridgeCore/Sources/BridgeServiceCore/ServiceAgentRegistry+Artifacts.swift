import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  func captureArtifacts(
    _ requests: [ServiceAgentInstallationArtifactRequest],
    at date: Date
  ) throws -> [ServiceAgentInstallationArtifact] {
    try requests.map { request in
      let identity = try captureArtifactIdentity(request.path, request.role.requiresExecutable)
      guard
        request.role != .launchConfiguration
          || identity.fileSize <= ServiceAgentFileIdentity.maximumConfigurationBytes
      else {
        throw ServiceStoreError.invalidArgument("agentInstallation.artifactSize")
      }
      return try ServiceAgentInstallationArtifact(
        role: request.role,
        identity: identity,
        createdAt: date,
        updatedAt: date
      )
    }
  }

  func captureArtifacts(
    _ artifacts: [ServiceAgentInstallationArtifact],
    at date: Date
  ) throws -> [ServiceAgentInstallationArtifact] {
    try artifacts.map { artifact in
      let identity = try captureArtifactIdentity(
        artifact.identity.canonicalPath,
        artifact.role.requiresExecutable
      )
      guard
        artifact.role != .launchConfiguration
          || identity.fileSize <= ServiceAgentFileIdentity.maximumConfigurationBytes
      else {
        throw ServiceStoreError.invalidArgument("agentInstallation.artifactSize")
      }
      return try ServiceAgentInstallationArtifact(
        role: artifact.role,
        identity: identity,
        createdAt: artifact.createdAt,
        updatedAt: date
      )
    }
  }

  func artifactsHaveSameIdentity(
    _ first: [ServiceAgentInstallationArtifact],
    _ second: [ServiceAgentInstallationArtifact]
  ) -> Bool {
    guard first.count == second.count else { return false }
    let firstByRole = Dictionary(uniqueKeysWithValues: first.map { ($0.role, $0.identity) })
    let secondByRole = Dictionary(uniqueKeysWithValues: second.map { ($0.role, $0.identity) })
    return firstByRole == secondByRole
  }
}
