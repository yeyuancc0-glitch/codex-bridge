import BridgeAgentCore

public enum ServiceAgentInstallationAvailability: String, Codable, CaseIterable, Sendable {
  case available
  case unavailable
  case needsReview = "needs_review"
}

public typealias ServiceAgentInstallationArtifactRole = AgentInstallationArtifactRole
