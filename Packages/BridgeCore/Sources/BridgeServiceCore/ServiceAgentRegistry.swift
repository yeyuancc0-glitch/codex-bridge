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

  private struct RegistrationKey: Hashable, Sendable {
    let providerID: AgentProviderID
    let canonicalPath: String
  }

  private let store: SimpleServiceStore
  private let providers: [AgentProviderID: any AgentProvider]
  private let makeInstallationID: @Sendable () -> AgentInstallationID
  private let captureIdentity: IdentityCapture
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
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let pairs = providers.map { ($0.descriptor.providerID, $0) }
    precondition(Set(pairs.map(\.0)).count == pairs.count)
    self.store = store
    self.providers = Dictionary(uniqueKeysWithValues: pairs)
    self.makeInstallationID = makeInstallationID
    self.captureIdentity = captureIdentity
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
    let installation = try AgentInstallation(
      id: record.id,
      providerID: record.providerID,
      executablePath: record.executableIdentity.canonicalPath,
      version: record.version,
      protocolRevision: record.protocolRevision
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
    createdAt: Date
  ) async throws -> ServiceAgentInstallationRecord {
    let installation = try AgentInstallation(
      id: id,
      providerID: provider.descriptor.providerID,
      executablePath: identity.canonicalPath
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
    } else if !hasVersion {
      reason = "The Provider did not report a version."
    } else {
      reason = result.unavailableReason ?? "The Provider is unavailable."
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
}
