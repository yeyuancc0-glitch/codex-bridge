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
    // Submission is enabled only for the read-only OpenCode slice: an
    // explicitly selectable installation whose effective capabilities still
    // include project reads under the managed sandbox.
    let submissionEnabled =
      record.providerID == .openCode
      && record.isSelectable
      && capabilities.contains(.workspaceRead)
    let workspaceEnforcement =
      submissionEnabled ? "os_sandbox" : "unavailable"
    // Tool network is governed by the provider permission policy, not the
    // seatbelt profile; report that honestly.
    let networkEnforcement = submissionEnabled ? "provider" : "unavailable"
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
      approvalEnforcement: "none",
      networkEnforcement: networkEnforcement,
      modelsSummary: [],
      unavailableReason: record.lastProbeError,
      lastVerifiedAt: record.lastProbedAt.map(formatter.string(from:))
    )
  }
}
