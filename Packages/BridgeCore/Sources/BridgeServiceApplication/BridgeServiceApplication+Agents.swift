import BridgeAgentCore
import BridgeMCP
import BridgeProjects
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceAgents(
    projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPAgentList {
    try Self.checkDeadline(deadline)
    let project: ServiceProjectRecord?
    if let projectID {
      project = try await readableProject(projectID)
    } else {
      project = nil
    }
    guard let agentRegistry else { return MCPAgentList(agents: []) }
    let records = try await agentRegistry.installations()
    try Self.checkDeadline(deadline)
    return MCPAgentList(
      agents: records.map { Self.agentSummary($0, project: project, formatter: iso8601) }
    )
  }

  private static func agentSummary(
    _ record: ServiceAgentInstallationRecord,
    project: ServiceProjectRecord?,
    formatter: ISO8601DateFormatter
  ) -> MCPAgentSummary {
    var capabilities = record.capabilities.effective
    if project?.accessPolicy.write == .denied {
      capabilities.remove(.workspaceWriteInPlace)
      capabilities.remove(.workspaceWriteIsolated)
    }
    // The persisted capability snapshot and project policy remain the public
    // source of truth for whether an installation may receive tasks.
    let submissionEnabled =
      (record.providerID == .openCode || record.providerID == .antigravity)
      && record.isSelectable
      && capabilities.contains(.workspaceRead)
    let workspaceEnforcement: String
    let approvalEnforcement: String
    let networkEnforcement: String
    switch record.providerID {
    case .openCode where submissionEnabled:
      workspaceEnforcement = "provider_native"
      approvalEnforcement = "local_app"
      networkEnforcement = "provider_native"
    case .antigravity where submissionEnabled:
      workspaceEnforcement = "os_sandbox_read_only"
      approvalEnforcement = "provider_soft_deny"
      networkEnforcement = "provider_native"
    default:
      workspaceEnforcement = "unavailable"
      approvalEnforcement = "unavailable"
      networkEnforcement = "unavailable"
    }
    return MCPAgentSummary(
      providerID: record.providerID.rawValue,
      installationID: record.id.rawValue,
      displayName: record.displayName,
      availability: record.availability.rawValue,
      enabled: record.isEnabled,
      taskSubmissionEnabled: submissionEnabled,
      version: record.version,
      protocolRevision: record.protocolRevision,
      adapterRevision: record.adapterRevision,
      effectiveCapabilities: capabilities.map(\.rawValue).sorted(),
      trustProfile: record.trustProfile.rawValue,
      securityProfileID: record.securityProfileID?.rawValue,
      workspaceEnforcement: workspaceEnforcement,
      approvalEnforcement: approvalEnforcement,
      networkEnforcement: networkEnforcement,
      modelsSummary: [],
      unavailableReason: record.lastProbeError,
      lastVerifiedAt: record.lastProbedAt.map(formatter.string(from:))
    )
  }
}
