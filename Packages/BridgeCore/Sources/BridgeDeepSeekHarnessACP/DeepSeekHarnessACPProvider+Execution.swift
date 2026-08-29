import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPProvider {
  public func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    try validate(request: request, installation: installation)
    let runDirectory = try makeRunDirectory(prefix: "run")
    var client: DeepSeekHarnessACPClient?
    do {
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        projectRoot: request.projectRoot,
        runDirectory: runDirectory,
        modelID: request.model,
        reasoningEffort: request.effort,
        mutationIntent: request.mutationIntent,
        networkAllowed: false,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      try validate(initialization)
      let capabilities = Self.capabilitySnapshot
      try require(request.requiredCapabilities, from: capabilities)
      let session = try await connected.newSession(cwd: request.projectRoot)
      let binding = try AgentBinding(
        providerID: .deepSeekHarness,
        installationID: installation.id,
        providerSessionID: session.id,
        providerRunID: UUID().uuidString.lowercased()
      )
      let normalizer = DeepSeekHarnessACPEventNormalizer(
        taskID: request.taskID,
        binding: binding,
        projectRoot: request.projectRoot
      )
      let initialSequence = await connected.eventSequence
      let execution = DeepSeekHarnessACPExecution(
        client: connected,
        normalizer: normalizer,
        sessionID: session.id,
        prompt: request.prompt,
        initialClientEventSequence: initialSequence,
        inactivityTimeout: configuration.inactivityTimeout,
        eventBufferLimit: configuration.eventBufferLimit,
        requiresCompletionAttestation: true,
        cleanup: {
          DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(launch.runDirectory)
        }
      )
      await execution.start()
      return AgentExecutionHandle(
        taskID: request.taskID,
        binding: binding,
        capabilities: capabilities,
        events: execution.events,
        control: AgentExecutionControl(
          interrupt: { try await execution.interrupt() },
          shutdown: { await execution.shutdown() },
          steer: { text in try await execution.steer(text: text) },
          resolveApproval: { approvalID, optionID in
            try await execution.resolveApproval(
              approvalID: approvalID,
              optionID: optionID
            )
          }
        )
      )
    } catch {
      await client?.shutdown()
      DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(runDirectory)
      throw Self.runtimeError(for: error)
    }
  }

  private func validate(
    request: AgentExecutionRequest,
    installation: AgentInstallation
  ) throws {
    guard installation.providerID == .deepSeekHarness else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    guard request.mutationIntent == .readOnly || request.mutationIntent == .workspaceWrite else {
      throw AgentRuntimeError.invalidRequest("request.mutationIntent")
    }
    guard
      request.workspaceStrategy == .sharedProject
        || request.workspaceStrategy == .exclusiveProject
    else {
      throw AgentRuntimeError.invalidRequest("request.workspaceStrategy")
    }
    guard !request.networkAccessRequested else {
      throw AgentRuntimeError.invalidRequest("request.networkAccessRequested")
    }
    guard request.requestedSessionID == nil else {
      throw AgentRuntimeError.capabilityUnavailable(.sessionContinue)
    }
    _ = try configuration.launchBuilder.profile.resolvedSelection(
      for: installation,
      modelID: request.model,
      reasoningEffort: request.effort
    )
    guard
      request.profileID == nil || request.profileID == DeepSeekHarnessACPProfiles.controlledReadOnly
    else {
      throw AgentRuntimeError.capabilityUnavailable(.profileSelection)
    }
  }

  private func require(
    _ required: Set<AgentCapability>,
    from snapshot: AgentCapabilitySnapshot
  ) throws {
    guard
      let missing = required.subtracting(snapshot.effective)
        .sorted(by: { $0.rawValue < $1.rawValue }).first
    else { return }
    throw AgentRuntimeError.capabilityUnavailable(missing)
  }
}
