import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  public func registerAndProbe(_ request: ServiceAgentRegistrationRequest) async throws
    -> ServiceAgentInstallationRecord
  {
    let provider = try provider(for: request.providerID)
    let identity = try captureIdentity(request.executablePath)
    let key = RegistrationKey(
      providerID: request.providerID,
      canonicalPath: identity.canonicalPath
    )
    guard activeRegistrations.insert(key).inserted else {
      throw ServiceAgentRegistryError.registrationInProgress(request.providerID)
    }
    defer { activeRegistrations.remove(key) }

    let registered = try await store.agentInstallations(providerID: request.providerID)
    if registered.contains(where: { $0.executableIdentity.canonicalPath == identity.canonicalPath })
    {
      throw ServiceStoreError.duplicateAgentExecutable(
        providerID: request.providerID,
        canonicalPath: identity.canonicalPath
      )
    }

    let createdAt = now()
    let artifacts = try captureArtifacts(request.artifactRequests, at: createdAt)
    let installationID = makeInstallationID()
    let record = try await probeRecord(
      id: installationID,
      provider: provider,
      displayName: request.displayName,
      executablePath: request.executablePath,
      identity: identity,
      trustProfile: request.trustProfile,
      securityProfileID: request.securityProfileID,
      isEnabled: request.enableOnSuccess,
      projectRoot: request.projectRoot,
      artifacts: artifacts,
      createdAt: createdAt
    )
    try await store.insertAgentInstallation(record)
    return record
  }

  public func reprobe(
    installationID: AgentInstallationID,
    acceptReplacement: Bool = false,
    projectRoot: String? = nil
  ) async throws -> ServiceAgentInstallationRecord {
    guard let existing = try await store.agentInstallation(id: installationID) else {
      throw ServiceStoreError.unknownAgentInstallation(installationID)
    }
    let provider = try provider(for: existing.providerID)
    let currentIdentity: ServiceAgentExecutableIdentity
    do {
      currentIdentity = try captureIdentity(existing.executablePath)
    } catch {
      let unavailable = try unavailableRecord(
        existing,
        availability: .unavailable,
        identity: existing.executableIdentity,
        reason: "The registered executable is unavailable.",
        probedAt: existing.lastProbedAt,
        updatedAt: now()
      )
      try await store.updateAgentInstallation(unavailable)
      return unavailable
    }

    if currentIdentity != existing.executableIdentity, !acceptReplacement {
      let review = try unavailableRecord(
        existing,
        availability: .needsReview,
        identity: existing.executableIdentity,
        reason: "The registered executable changed and requires local review.",
        probedAt: existing.lastProbedAt,
        updatedAt: now()
      )
      try await store.updateAgentInstallation(review)
      return review
    }

    let currentArtifacts: [ServiceAgentInstallationArtifact]
    do {
      currentArtifacts = try captureArtifacts(existing.artifacts, at: now())
    } catch {
      let review = try unavailableRecord(
        existing,
        availability: .needsReview,
        identity: existing.executableIdentity,
        artifacts: existing.artifacts,
        reason: "A registered installation artifact is unavailable and requires local review.",
        probedAt: existing.lastProbedAt,
        updatedAt: now()
      )
      try await store.updateAgentInstallation(review)
      return review
    }
    let artifactsChanged = !artifactsHaveSameIdentity(currentArtifacts, existing.artifacts)
    if artifactsChanged, !acceptReplacement {
      let review = try unavailableRecord(
        existing,
        availability: .needsReview,
        identity: existing.executableIdentity,
        artifacts: existing.artifacts,
        reason: "A registered installation artifact changed and requires local review.",
        probedAt: existing.lastProbedAt,
        updatedAt: now()
      )
      try await store.updateAgentInstallation(review)
      return review
    }
    let artifactsForProbe = artifactsChanged ? currentArtifacts : existing.artifacts

    let record = try await probeRecord(
      id: existing.id,
      provider: provider,
      displayName: existing.displayName,
      executablePath: existing.executablePath,
      identity: currentIdentity,
      trustProfile: existing.trustProfile,
      securityProfileID: existing.securityProfileID,
      isEnabled: existing.isEnabled,
      projectRoot: projectRoot,
      artifacts: artifactsForProbe,
      createdAt: existing.createdAt
    )
    try await store.updateAgentInstallation(record)
    return record
  }

  public func setEnabled(
    _ enabled: Bool,
    installationID: AgentInstallationID
  ) async throws -> ServiceAgentInstallationRecord {
    guard let existing = try await store.agentInstallation(id: installationID) else {
      throw ServiceStoreError.unknownAgentInstallation(installationID)
    }
    if enabled {
      let provider = try provider(for: existing.providerID)
      guard provider.descriptor.adapterRevision == existing.adapterRevision else {
        let review = try unavailableRecord(
          existing,
          availability: .needsReview,
          identity: existing.executableIdentity,
          reason: "The Provider adapter changed and requires a new Probe.",
          probedAt: existing.lastProbedAt,
          updatedAt: now()
        )
        try await store.updateAgentInstallation(review)
        throw ServiceAgentRegistryError.installationNeedsReview(installationID)
      }
      let current = try captureIdentity(existing.executablePath)
      guard current == existing.executableIdentity else {
        let review = try unavailableRecord(
          existing,
          availability: .needsReview,
          identity: existing.executableIdentity,
          reason: "The registered executable changed and requires local review.",
          probedAt: existing.lastProbedAt,
          updatedAt: now()
        )
        try await store.updateAgentInstallation(review)
        throw ServiceAgentRegistryError.installationNeedsReview(installationID)
      }
      do {
        let currentArtifacts = try captureArtifacts(existing.artifacts, at: now())
        guard artifactsHaveSameIdentity(currentArtifacts, existing.artifacts) else {
          let review = try unavailableRecord(
            existing,
            availability: .needsReview,
            identity: existing.executableIdentity,
            artifacts: existing.artifacts,
            reason: "A registered installation artifact changed and requires local review.",
            probedAt: existing.lastProbedAt,
            updatedAt: now()
          )
          try await store.updateAgentInstallation(review)
          throw ServiceAgentRegistryError.installationNeedsReview(installationID)
        }
      } catch let error as ServiceAgentRegistryError {
        throw error
      } catch {
        let review = try unavailableRecord(
          existing,
          availability: .needsReview,
          identity: existing.executableIdentity,
          artifacts: existing.artifacts,
          reason: "A registered installation artifact is unavailable and requires local review.",
          probedAt: existing.lastProbedAt,
          updatedAt: now()
        )
        try await store.updateAgentInstallation(review)
        throw ServiceAgentRegistryError.installationNeedsReview(installationID)
      }
      guard existing.availability == .available else {
        if existing.availability == .needsReview {
          throw ServiceAgentRegistryError.installationNeedsReview(installationID)
        }
        throw ServiceAgentRegistryError.installationUnavailable(installationID)
      }
    }
    let updated = try existing.replacingEnabled(enabled, updatedAt: now())
    try await store.updateAgentInstallation(updated)
    return updated
  }
}
