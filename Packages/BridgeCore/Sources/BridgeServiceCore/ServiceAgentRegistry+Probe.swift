import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  func probeRecord(
    id: AgentInstallationID,
    provider: any AgentProvider,
    displayName: String,
    executablePath: String,
    identity: ServiceAgentExecutableIdentity,
    trustProfile: AgentTrustProfile,
    securityProfileID: AgentProfileID?,
    isEnabled: Bool,
    projectRoot: String?,
    artifacts: [ServiceAgentInstallationArtifact],
    createdAt: Date
  ) async throws -> ServiceAgentInstallationRecord {
    let installation = try AgentInstallation(
      id: id,
      providerID: provider.descriptor.providerID,
      executablePath: identity.canonicalPath,
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
    let request = try AgentProbeRequest(
      installation: installation,
      projectRoot: projectRoot
    )
    let result = await provider.probe(request)
    let completedAt = now()
    let afterIdentity: ServiceAgentExecutableIdentity
    do {
      afterIdentity = try captureIdentity(executablePath)
    } catch {
      return try probeReviewRecord(
        id: id,
        provider: provider,
        displayName: displayName,
        executablePath: executablePath,
        identity: identity,
        trustProfile: trustProfile,
        securityProfileID: securityProfileID,
        isEnabled: isEnabled,
        result: result,
        artifacts: artifacts,
        reason: "The executable changed while the Probe was running.",
        completedAt: completedAt,
        createdAt: createdAt
      )
    }
    guard afterIdentity == identity else {
      return try probeReviewRecord(
        id: id,
        provider: provider,
        displayName: displayName,
        executablePath: executablePath,
        identity: identity,
        trustProfile: trustProfile,
        securityProfileID: securityProfileID,
        isEnabled: isEnabled,
        result: result,
        artifacts: artifacts,
        reason: "The executable changed while the Probe was running.",
        completedAt: completedAt,
        createdAt: createdAt
      )
    }

    let resultMatches =
      result.installation.id == id
      && result.installation.providerID == provider.descriptor.providerID
      && result.installation.executablePath == identity.canonicalPath
    let observedArtifacts: [ServiceAgentInstallationArtifact]
    do {
      observedArtifacts = try captureArtifacts(artifacts, at: completedAt)
    } catch {
      return try probeReviewRecord(
        id: id,
        provider: provider,
        displayName: displayName,
        executablePath: executablePath,
        identity: identity,
        trustProfile: trustProfile,
        securityProfileID: securityProfileID,
        isEnabled: isEnabled,
        result: result,
        artifacts: artifacts,
        reason: "A registered installation artifact changed while the Probe was running.",
        completedAt: completedAt,
        createdAt: createdAt
      )
    }
    guard artifactsHaveSameIdentity(observedArtifacts, artifacts) else {
      return try probeReviewRecord(
        id: id,
        provider: provider,
        displayName: displayName,
        executablePath: executablePath,
        identity: identity,
        trustProfile: trustProfile,
        securityProfileID: securityProfileID,
        isEnabled: isEnabled,
        result: result,
        artifacts: artifacts,
        reason: "A registered installation artifact changed while the Probe was running.",
        completedAt: completedAt,
        createdAt: createdAt
      )
    }
    let hasVersion = result.installation.version != nil
    let available = result.available && resultMatches && hasVersion
    let availability: ServiceAgentInstallationAvailability
    if available {
      availability = .available
    } else if result.reviewRequired || !resultMatches {
      availability = .needsReview
    } else {
      availability = .unavailable
    }
    let reason: String?
    if available {
      reason = nil
    } else if !resultMatches {
      reason = "The Provider returned a mismatched installation identity."
    } else if !result.available {
      reason = result.unavailableReason ?? "The Provider is unavailable."
    } else {
      reason = "The Provider did not report a version."
    }
    return try ServiceAgentInstallationRecord(
      id: id,
      providerID: provider.descriptor.providerID,
      displayName: displayName,
      executablePath: executablePath,
      executableIdentity: identity,
      version: result.installation.version,
      protocolRevision: result.installation.protocolRevision,
      adapterRevision: provider.descriptor.adapterRevision,
      trustProfile: trustProfile,
      securityProfileID: securityProfileID,
      isEnabled: isEnabled,
      availability: availability,
      capabilities: available ? result.capabilities : .empty,
      artifacts: artifacts,
      lastProbeError: reason,
      lastProbedAt: completedAt,
      createdAt: createdAt,
      updatedAt: completedAt
    )
  }

  private func probeReviewRecord(
    id: AgentInstallationID,
    provider: any AgentProvider,
    displayName: String,
    executablePath: String,
    identity: ServiceAgentExecutableIdentity,
    trustProfile: AgentTrustProfile,
    securityProfileID: AgentProfileID?,
    isEnabled: Bool,
    result: AgentProbeResult,
    artifacts: [ServiceAgentInstallationArtifact],
    reason: String,
    completedAt: Date,
    createdAt: Date
  ) throws -> ServiceAgentInstallationRecord {
    try ServiceAgentInstallationRecord(
      id: id,
      providerID: provider.descriptor.providerID,
      displayName: displayName,
      executablePath: executablePath,
      executableIdentity: identity,
      version: result.installation.version,
      protocolRevision: result.installation.protocolRevision,
      adapterRevision: provider.descriptor.adapterRevision,
      trustProfile: trustProfile,
      securityProfileID: securityProfileID,
      isEnabled: isEnabled,
      availability: .needsReview,
      capabilities: .empty,
      artifacts: artifacts,
      lastProbeError: reason,
      lastProbedAt: completedAt,
      createdAt: createdAt,
      updatedAt: completedAt
    )
  }

  func unavailableRecord(
    _ existing: ServiceAgentInstallationRecord,
    availability: ServiceAgentInstallationAvailability,
    identity: ServiceAgentExecutableIdentity,
    artifacts: [ServiceAgentInstallationArtifact]? = nil,
    reason: String,
    probedAt: Date?,
    updatedAt: Date
  ) throws -> ServiceAgentInstallationRecord {
    try ServiceAgentInstallationRecord(
      id: existing.id,
      providerID: existing.providerID,
      displayName: existing.displayName,
      executablePath: existing.executablePath,
      executableIdentity: identity,
      version: existing.version,
      protocolRevision: existing.protocolRevision,
      adapterRevision: existing.adapterRevision,
      trustProfile: existing.trustProfile,
      securityProfileID: existing.securityProfileID,
      isEnabled: existing.isEnabled,
      availability: availability,
      capabilities: .empty,
      artifacts: artifacts ?? existing.artifacts,
      lastProbeError: reason,
      lastProbedAt: probedAt,
      createdAt: existing.createdAt,
      updatedAt: updatedAt
    )
  }

  func provider(for providerID: AgentProviderID) throws -> any AgentProvider {
    guard let provider = providers[providerID] else {
      throw ServiceAgentRegistryError.providerUnavailable(providerID)
    }
    return provider
  }
}
