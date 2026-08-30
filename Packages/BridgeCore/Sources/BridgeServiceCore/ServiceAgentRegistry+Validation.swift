import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  public func validateForExecution(
    installationID: AgentInstallationID
  ) async throws -> ServiceAgentInstallationRecord {
    guard let record = try await store.agentInstallation(id: installationID) else {
      throw ServiceStoreError.unknownAgentInstallation(installationID)
    }
    guard record.isSelectable else {
      if record.availability == .needsReview {
        throw ServiceAgentRegistryError.installationNeedsReview(installationID)
      }
      throw ServiceAgentRegistryError.installationUnavailable(installationID)
    }
    guard let provider = providers[record.providerID] else {
      throw ServiceAgentRegistryError.providerUnavailable(record.providerID)
    }
    guard provider.descriptor.adapterRevision == record.adapterRevision else {
      _ = try await persistStateIfNeeded(
        record,
        availability: .needsReview,
        reason: "The Provider adapter changed and requires a new Probe."
      )
      throw ServiceAgentRegistryError.installationNeedsReview(installationID)
    }
    do {
      let current = try captureIdentity(record.executablePath)
      guard current == record.executableIdentity else {
        _ = try await persistStateIfNeeded(
          record,
          availability: .needsReview,
          reason: "The registered executable changed and requires local review."
        )
        throw ServiceAgentRegistryError.installationNeedsReview(installationID)
      }
    } catch let error as ServiceAgentRegistryError {
      throw error
    } catch {
      _ = try await persistStateIfNeeded(
        record,
        availability: .unavailable,
        reason: "The registered executable is unavailable."
      )
      throw ServiceAgentRegistryError.installationUnavailable(installationID)
    }
    do {
      let currentArtifacts = try captureArtifacts(record.artifacts, at: now())
      guard artifactsHaveSameIdentity(currentArtifacts, record.artifacts) else {
        _ = try await persistStateIfNeeded(
          record,
          availability: .needsReview,
          reason: "A registered installation artifact changed and requires local review."
        )
        throw ServiceAgentRegistryError.installationNeedsReview(installationID)
      }
    } catch let error as ServiceAgentRegistryError {
      throw error
    } catch {
      _ = try await persistStateIfNeeded(
        record,
        availability: .needsReview,
        reason: "A registered installation artifact is unavailable and requires local review."
      )
      throw ServiceAgentRegistryError.installationNeedsReview(installationID)
    }
    return record
  }

  public func models(
    installationID: AgentInstallationID,
    projectRoot: String? = nil,
    selectedModelID: String? = nil
  ) async throws -> [AgentModelDescriptor] {
    guard let record = try await store.agentInstallation(id: installationID),
      record.isSelectable
    else {
      throw ServiceAgentRegistryError.installationUnavailable(installationID)
    }
    let provider = try provider(for: record.providerID)
    guard provider.descriptor.adapterRevision == record.adapterRevision else {
      throw ServiceAgentRegistryError.installationNeedsReview(installationID)
    }
    let currentIdentity = try captureIdentity(record.executablePath)
    guard currentIdentity == record.executableIdentity else {
      throw ServiceAgentRegistryError.installationNeedsReview(installationID)
    }
    let currentArtifacts = try captureArtifacts(record.artifacts, at: now())
    guard artifactsHaveSameIdentity(currentArtifacts, record.artifacts) else {
      throw ServiceAgentRegistryError.installationNeedsReview(installationID)
    }
    let installation = try AgentInstallation(
      id: record.id,
      providerID: record.providerID,
      executablePath: record.executableIdentity.canonicalPath,
      version: record.version,
      protocolRevision: record.protocolRevision,
      artifacts: record.artifacts.map { artifact in
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
    return try await provider.models(
      installation: installation,
      projectRoot: projectRoot,
      selectedModelID: selectedModelID
    )
  }

  @discardableResult
  public func refreshInstallationStates() async throws -> [ServiceAgentInstallationRecord] {
    let records = try await store.agentInstallations()
    var refreshed: [ServiceAgentInstallationRecord] = []
    refreshed.reserveCapacity(records.count)
    for record in records {
      let updated = try await refreshedRecord(record)
      refreshed.append(updated)
    }
    return refreshed
  }

  func refreshedRecord(_ record: ServiceAgentInstallationRecord) async throws
    -> ServiceAgentInstallationRecord
  {
    guard let provider = providers[record.providerID] else {
      return try await persistStateIfNeeded(
        record,
        availability: .unavailable,
        reason: "The Provider adapter is unavailable."
      )
    }
    guard provider.descriptor.adapterRevision == record.adapterRevision else {
      return try await persistStateIfNeeded(
        record,
        availability: .needsReview,
        reason: "The Provider adapter changed and requires a new Probe."
      )
    }
    let current: ServiceAgentExecutableIdentity
    do {
      current = try captureIdentity(record.executablePath)
    } catch {
      return try await persistStateIfNeeded(
        record,
        availability: .unavailable,
        reason: "The registered executable is unavailable."
      )
    }
    guard current == record.executableIdentity else {
      return try await persistStateIfNeeded(
        record,
        availability: .needsReview,
        reason: "The registered executable changed and requires local review."
      )
    }
    do {
      let currentArtifacts = try captureArtifacts(record.artifacts, at: now())
      guard artifactsHaveSameIdentity(currentArtifacts, record.artifacts) else {
        return try await persistStateIfNeeded(
          record,
          availability: .needsReview,
          reason: "A registered installation artifact changed and requires local review."
        )
      }
    } catch {
      return try await persistStateIfNeeded(
        record,
        availability: .needsReview,
        reason: "A registered installation artifact is unavailable and requires local review."
      )
    }
    return record
  }

  func persistStateIfNeeded(
    _ record: ServiceAgentInstallationRecord,
    availability: ServiceAgentInstallationAvailability,
    reason: String
  ) async throws -> ServiceAgentInstallationRecord {
    if record.availability == availability,
      record.capabilities == .empty,
      record.lastProbeError == reason
    {
      return record
    }
    let updated = try unavailableRecord(
      record,
      availability: availability,
      identity: record.executableIdentity,
      reason: reason,
      probedAt: record.lastProbedAt,
      updatedAt: now()
    )
    try await store.updateAgentInstallation(updated)
    return updated
  }
}
