import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import Foundation

public struct AgentTaskBrief: Sendable {
  public let taskID: TaskID
  public let providerID: AgentProviderID
  public let installationID: AgentInstallationID
  public let projectID: ProjectID
  public let projectRoot: String
  public let prompt: String
  public let requestedSessionID: String?
  public let model: String?
  public let effort: String?
  public let permissionMode: ServicePermissionMode
  public let profileID: AgentProfileID?
  public let networkAllowed: Bool

  public init(
    taskID: TaskID,
    providerID: AgentProviderID,
    installationID: AgentInstallationID,
    projectID: ProjectID,
    projectRoot: String,
    prompt: String,
    requestedSessionID: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    permissionMode: ServicePermissionMode = .readOnly,
    profileID: AgentProfileID? = nil,
    networkAllowed: Bool
  ) {
    self.taskID = taskID
    self.providerID = providerID
    self.installationID = installationID
    self.projectID = projectID
    self.projectRoot = projectRoot
    self.prompt = prompt
    self.requestedSessionID = requestedSessionID
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.profileID = profileID
    self.networkAllowed = networkAllowed
  }
}

public struct AgentTaskRunHandle: Sendable {
  public let sessionID: String?
  public let runID: String?
  public let events: AsyncThrowingStream<AgentEventEnvelope, any Error>
  public let interrupt: @Sendable () async throws -> Void
  public let steer: (@Sendable (String) async throws -> Void)?
  public let shutdown: @Sendable () async -> Void
  public let resolveApproval: (@Sendable (String, String) async throws -> Void)?

  public init(
    sessionID: String?,
    runID: String?,
    events: AsyncThrowingStream<AgentEventEnvelope, any Error>,
    interrupt: @escaping @Sendable () async throws -> Void,
    steer: (@Sendable (String) async throws -> Void)? = nil,
    shutdown: @escaping @Sendable () async -> Void,
    resolveApproval: (@Sendable (String, String) async throws -> Void)? = nil
  ) {
    self.sessionID = sessionID
    self.runID = runID
    self.events = events
    self.interrupt = interrupt
    self.steer = steer
    self.shutdown = shutdown
    self.resolveApproval = resolveApproval
  }
}

public protocol AgentTaskRunning: Sendable {
  func start(_ brief: AgentTaskBrief) async throws -> AgentTaskRunHandle
}

/// Starts agent runs for user-registered installations. The registry remains
/// the single source of truth for which installations may execute; the runner
/// never launches a binary that the user has not explicitly enabled.
public struct ServiceAgentTaskRunner: AgentTaskRunning {
  private let registry: ServiceAgentRegistry?
  private let providers: [AgentProviderID: any AgentProvider]

  public init(
    registry: ServiceAgentRegistry?,
    providers: [AgentProviderID: any AgentProvider]
  ) {
    self.registry = registry
    self.providers = providers
  }

  public func start(_ brief: AgentTaskBrief) async throws -> AgentTaskRunHandle {
    guard let registry else {
      throw AgentRuntimeError.providerUnavailable(brief.providerID)
    }
    let record: ServiceAgentInstallationRecord
    do {
      record = try await registry.reprobe(
        installationID: brief.installationID,
        acceptReplacement: false,
        projectRoot: brief.projectRoot
      )
    } catch ServiceAgentRegistryError.installationUnavailable {
      throw AgentRuntimeError.installationUnavailable(brief.installationID)
    } catch ServiceAgentRegistryError.installationNeedsReview {
      throw AgentRuntimeError.installationUnavailable(brief.installationID)
    } catch {
      throw AgentRuntimeError.installationUnavailable(brief.installationID)
    }
    guard let provider = providers[brief.providerID] else {
      throw AgentRuntimeError.providerUnavailable(brief.providerID)
    }
    guard
      record.isSelectable, record.providerID == brief.providerID
    else {
      throw AgentRuntimeError.installationUnavailable(brief.installationID)
    }
    if let profileID = brief.profileID, record.securityProfileID != profileID {
      throw AgentRuntimeError.invalidRequest("request.profileID")
    }
    let requiredCapabilities: Set<AgentCapability> =
      brief.permissionMode == .workspaceWrite
      ? [.workspaceRead, .workspaceWriteInPlace]
      : [.workspaceRead]
    guard record.capabilities.supports(requiredCapabilities) else {
      let missing = requiredCapabilities.subtracting(record.capabilities.effective)
      guard let capability = missing.sorted(by: { $0.rawValue < $1.rawValue }).first else {
        throw AgentRuntimeError.capabilityUnavailable(.workspaceRead)
      }
      throw AgentRuntimeError.capabilityUnavailable(capability)
    }
    // The frozen canonical path from registration time is the only executable
    // identity this runner will launch.
    let installation = try AgentInstallation(
      id: record.id,
      providerID: record.providerID,
      executablePath: record.executableIdentity.canonicalPath,
      version: record.version,
      protocolRevision: record.protocolRevision
    )
    let request = try AgentExecutionRequest(
      taskID: brief.taskID,
      projectID: brief.projectID,
      projectRoot: brief.projectRoot,
      prompt: brief.prompt,
      requestedSessionID: brief.requestedSessionID,
      model: brief.model,
      effort: brief.effort,
      profileID: brief.profileID ?? record.securityProfileID,
      mutationIntent: brief.permissionMode == .workspaceWrite ? .workspaceWrite : .readOnly,
      workspaceStrategy: brief.permissionMode == .workspaceWrite
        ? .exclusiveProject : .sharedProject,
      networkAccessRequested: brief.networkAllowed,
      requiredCapabilities: requiredCapabilities
    )
    let handle = try await provider.start(request, installation: installation)
    guard handle.taskID == brief.taskID,
      handle.binding.providerID == brief.providerID,
      handle.binding.installationID == brief.installationID
    else {
      if let shutdown = handle.control.shutdown {
        await shutdown()
      } else {
        try? await handle.control.interrupt()
      }
      throw AgentRuntimeError.malformedEvent("agent.handle.binding")
    }
    return AgentTaskRunHandle(
      sessionID: handle.binding.providerSessionID,
      runID: handle.binding.providerRunID,
      events: handle.events,
      interrupt: handle.control.interrupt,
      steer: handle.control.steer,
      shutdown: handle.control.shutdown ?? {
        try? await handle.control.interrupt()
      },
      resolveApproval: handle.control.resolveApproval
    )
  }
}
