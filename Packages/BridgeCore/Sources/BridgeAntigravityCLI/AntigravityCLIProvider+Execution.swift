import BridgeAgentCore
import Foundation

extension AntigravityCLIProvider {
  public func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    try validate(request: request, installation: installation)
    var requiredCapabilities = request.requiredCapabilities
    requiredCapabilities.insert(
      request.mutationIntent == .readOnly ? .workspaceRead : .workspaceWriteInPlace
    )
    if request.requestedSessionID != nil { requiredCapabilities.insert(.sessionContinue) }
    if request.model != nil { requiredCapabilities.insert(.modelSelection) }
    if request.effort != nil { requiredCapabilities.insert(.effortSelection) }
    try require(requiredCapabilities, from: Self.runtimeCapabilities)
    let runDirectory = try makeRunDirectory()
    var execution: AntigravityCLIExecution?

    do {
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        request: request,
        runDirectory: runDirectory,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let connected = try configuration.transportFactory(launch)
      let active = AntigravityCLIExecution(
        taskID: request.taskID,
        installationID: installation.id,
        projectRoot: launch.process.workingDirectory,
        requestedSessionID: request.requestedSessionID,
        expectedModel: request.model,
        prompt: AntigravityCLIHeadlessPolicy.prompt(request.prompt),
        transport: connected,
        inactivityTimeout: configuration.inactivityTimeout,
        eventBufferLimit: configuration.eventBufferLimit,
        cleanup: {
          AntigravityCLILaunchBuilder.removeRunDirectory(launch.runDirectory)
        }
      )
      execution = active
      await active.start()
      let binding = try await active.waitForBinding(timeout: configuration.requestTimeout)
      var observed = Self.runtimeCapabilities.observed
      observed.insert(.sessionCreate)
      observed.formUnion(await active.observedNativeToolCapabilities())
      let runCapabilities = Self.capabilities(observed: observed)
      let steer: (@Sendable (String) async throws -> Void)?
      if runCapabilities.effective.contains(.steer) {
        steer = { text in try await active.steer(text: text) }
      } else {
        steer = nil
      }
      return AgentExecutionHandle(
        taskID: request.taskID,
        binding: binding,
        capabilities: runCapabilities,
        events: active.events,
        control: AgentExecutionControl(
          interrupt: { try await active.interrupt() },
          shutdown: { await active.shutdown() },
          steer: steer
        )
      )
    } catch {
      await execution?.shutdown()
      AntigravityCLILaunchBuilder.removeRunDirectory(runDirectory)
      throw Self.runtimeError(error)
    }
  }

  func validate(
    request: AgentExecutionRequest,
    installation: AgentInstallation
  ) throws {
    guard installation.providerID == .antigravity else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let expectedStrategy: AgentWorkspaceStrategy =
      request.mutationIntent == .readOnly ? .sharedProject : .exclusiveProject
    guard request.workspaceStrategy == expectedStrategy
    else {
      throw AgentRuntimeError.capabilityUnavailable(.workspaceWriteInPlace)
    }
    guard request.profileID == nil || request.profileID == AntigravityCLIProfiles.desktopShared
    else {
      throw AgentRuntimeError.invalidRequest("request.profileID")
    }
    if let model = request.model {
      guard !model.isEmpty, model.utf8.count <= 256,
        !model.contains("\0"), model.rangeOfCharacter(from: .controlCharacters) == nil
      else {
        throw AgentRuntimeError.invalidRequest("request.model")
      }
    }
    if let effort = request.effort, !["low", "medium", "high"].contains(effort) {
      throw AgentRuntimeError.invalidRequest("request.effort")
    }
  }

  func require(
    _ required: Set<AgentCapability>,
    from snapshot: AgentCapabilitySnapshot
  ) throws {
    guard
      let missing = required.subtracting(snapshot.effective)
        .sorted(by: { $0.rawValue < $1.rawValue }).first
    else { return }
    throw AgentRuntimeError.capabilityUnavailable(missing)
  }

  static let advertisedCapabilities: Set<AgentCapability> = [
    .sessionCreate,
    .sessionContinue,
    .interrupt,
    .steer,
    .toolLifecycle,
    .usage,
    .workspaceRead,
    .workspaceWriteInPlace,
    .modelSelection,
    .effortSelection,
    .shell,
    .webSearch,
    .webFetch,
    .mcpClient,
    .subagents,
    .childRuns,
  ]

  static let enforcedCapabilities: Set<AgentCapability> = [
    .sessionCreate,
    .sessionContinue,
    .interrupt,
    .steer,
    .toolLifecycle,
    .usage,
    .workspaceRead,
    .workspaceWriteInPlace,
    .modelSelection,
    .effortSelection,
    .shell,
    .webSearch,
    .webFetch,
    .mcpClient,
    .subagents,
    .childRuns,
  ]

  static let runtimeCapabilities = capabilities(
    observed: [
      .sessionCreate,
      .sessionContinue,
      .steer,
      .toolLifecycle,
      .usage,
      .workspaceRead,
      .workspaceWriteInPlace,
      .modelSelection,
      .effortSelection,
    ]
  )

  static func capabilities(
    observed: Set<AgentCapability>
  ) -> AgentCapabilitySnapshot {
    AgentCapabilitySnapshot(
      advertised: advertisedCapabilities,
      observed: observed,
      enforced: enforcedCapabilities
    )
  }
}
