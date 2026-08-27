import BridgeAgentCore
import Foundation

public enum ServiceAgentRegistryError: Error, Equatable, LocalizedError, Sendable {
  case providerUnavailable(AgentProviderID)
  case installationUnavailable(AgentInstallationID)
  case installationNeedsReview(AgentInstallationID)
  case registrationInProgress(AgentProviderID)

  public var errorDescription: String? {
    switch self {
    case .providerUnavailable:
      "The Agent Provider is not registered with this service."
    case .installationUnavailable:
      "The Agent installation is unavailable."
    case .installationNeedsReview:
      "The Agent installation changed and requires local review."
    case .registrationInProgress:
      "The Agent executable is already being registered."
    }
  }
}

public actor ServiceAgentRegistry {
  public typealias IdentityCapture = @Sendable (String) throws -> ServiceAgentExecutableIdentity
  public typealias ArtifactIdentityCapture =
    @Sendable (String, Bool) throws -> ServiceAgentFileIdentity

  private struct RegistrationKey: Hashable, Sendable {
    let providerID: AgentProviderID
    let canonicalPath: String
  }

  private let store: SimpleServiceStore
  private let providers: [AgentProviderID: any AgentProvider]
  private let makeInstallationID: @Sendable () -> AgentInstallationID
  private let captureIdentity: IdentityCapture
  private let captureArtifactIdentity: ArtifactIdentityCapture
  private let now: @Sendable () -> Date
  private var activeRegistrations: Set<RegistrationKey> = []

  public init(
    store: SimpleServiceStore,
    providers: [any AgentProvider],
    makeInstallationID: @escaping @Sendable () -> AgentInstallationID = {
      AgentInstallationID(rawValue: "ainst-\(UUID().uuidString.lowercased())")
    },
    captureIdentity: @escaping IdentityCapture = { path in
      try ServiceAgentExecutableIdentity(capturing: path)
    },
    captureArtifactIdentity: @escaping ArtifactIdentityCapture = { path, requiresExecutable in
      try ServiceAgentFileIdentity(capturing: path, requiresExecutable: requiresExecutable)
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let pairs = providers.map { ($0.descriptor.providerID, $0) }
    precondition(Set(pairs.map(\.0)).count == pairs.count)
    self.store = store
    self.providers = Dictionary(uniqueKeysWithValues: pairs)
    self.makeInstallationID = makeInstallationID
    self.captureIdentity = captureIdentity
    self.captureArtifactIdentity = captureArtifactIdentity
    self.now = now
  }

  public func providerDescriptors() -> [AgentProviderDescriptor] {
    providers.values.map(\.descriptor).sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

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

  public func installation(id: AgentInstallationID) async throws
    -> ServiceAgentInstallationRecord?
  {
    try await store.agentInstallation(id: id)
  }

  public func installations(providerID: AgentProviderID? = nil) async throws
    -> [ServiceAgentInstallationRecord]
  {
    try await store.agentInstallations(providerID: providerID)
  }

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

  public func remove(installationID: AgentInstallationID) async throws {
    try await store.removeAgentInstallation(id: installationID)
  }

  private func refreshedRecord(_ record: ServiceAgentInstallationRecord) async throws
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

  private func persistStateIfNeeded(
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

  private func probeRecord(
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
        availability: .needsReview,
        capabilities: .empty,
        artifacts: artifacts,
        lastProbeError: "The executable changed while the Probe was running.",
        lastProbedAt: completedAt,
        createdAt: createdAt,
        updatedAt: completedAt
      )
    }
    guard afterIdentity == identity else {
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
        availability: .needsReview,
        capabilities: .empty,
        artifacts: artifacts,
        lastProbeError: "The executable changed while the Probe was running.",
        lastProbedAt: completedAt,
        createdAt: createdAt,
        updatedAt: completedAt
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
        availability: .needsReview,
        capabilities: .empty,
        artifacts: artifacts,
        lastProbeError: "A registered installation artifact changed while the Probe was running.",
        lastProbedAt: completedAt,
        createdAt: createdAt,
        updatedAt: completedAt
      )
    }
    guard artifactsHaveSameIdentity(observedArtifacts, artifacts) else {
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
        availability: .needsReview,
        capabilities: .empty,
        artifacts: artifacts,
        lastProbeError: "A registered installation artifact changed while the Probe was running.",
        lastProbedAt: completedAt,
        createdAt: createdAt,
        updatedAt: completedAt
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

  private func unavailableRecord(
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

  private func provider(for providerID: AgentProviderID) throws -> any AgentProvider {
    guard let provider = providers[providerID] else {
      throw ServiceAgentRegistryError.providerUnavailable(providerID)
    }
    return provider
  }

  private func captureArtifacts(
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

  private func captureArtifacts(
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

  private func artifactsHaveSameIdentity(
    _ first: [ServiceAgentInstallationArtifact],
    _ second: [ServiceAgentInstallationArtifact]
  ) -> Bool {
    guard first.count == second.count else { return false }
    let firstByRole = Dictionary(uniqueKeysWithValues: first.map { ($0.role, $0.identity) })
    let secondByRole = Dictionary(uniqueKeysWithValues: second.map { ($0.role, $0.identity) })
    return firstByRole == secondByRole
  }
}
