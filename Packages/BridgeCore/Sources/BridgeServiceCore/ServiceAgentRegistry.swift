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

  struct RegistrationKey: Hashable, Sendable {
    let providerID: AgentProviderID
    let canonicalPath: String
  }

  let store: SimpleServiceStore
  let providers: [AgentProviderID: any AgentProvider]
  let makeInstallationID: @Sendable () -> AgentInstallationID
  let captureIdentity: IdentityCapture
  let captureArtifactIdentity: ArtifactIdentityCapture
  let now: @Sendable () -> Date
  var activeRegistrations: Set<RegistrationKey> = []

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

  public func remove(installationID: AgentInstallationID) async throws {
    try await store.removeAgentInstallation(id: installationID)
  }
}
