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
    let persistedRecords = try await agentRegistry.installations()
    var records: [ServiceAgentInstallationRecord] = []
    records.reserveCapacity(persistedRecords.count)
    for record in persistedRecords {
      try Self.checkDeadline(deadline)
      guard record.isSelectable else {
        records.append(record)
        continue
      }
      do {
        records.append(
          try await agentRegistry.validateForExecution(installationID: record.id)
        )
      } catch {
        records.append(try await agentRegistry.installation(id: record.id) ?? record)
      }
    }
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
    let policy = ServiceAgentProviderPolicyRegistry.policy(for: record.providerID)
    let projectAllowsWorkspaceWrite = project?.accessPolicy.write != .denied
    var capabilities = record.capabilities.effective
    if let policy {
      capabilities = policy.effectiveCapabilities(
        capabilities,
        projectAllowsWorkspaceWrite: projectAllowsWorkspaceWrite
      )
    } else if !projectAllowsWorkspaceWrite {
      capabilities.remove(.workspaceWriteInPlace)
      capabilities.remove(.workspaceWriteIsolated)
    }
    let submissionEnabled =
      policy?.taskSubmissionEnabled(
        isSelectable: record.isSelectable,
        capabilities: capabilities,
        artifactRoles: Set(record.artifacts.map(\.role)),
        version: record.version,
        protocolRevision: record.protocolRevision
      ) ?? false
    let workspaceEnforcement =
      submissionEnabled
      ? policy?.workspaceEnforcement ?? "unavailable"
      : "unavailable"
    let approvalEnforcement =
      submissionEnabled
      ? policy?.approvalEnforcement ?? "unavailable"
      : "unavailable"
    let networkEnforcement =
      submissionEnabled
      ? policy?.networkEnforcement ?? "unavailable"
      : "unavailable"
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
