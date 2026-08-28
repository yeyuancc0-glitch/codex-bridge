import BridgeAgentCore
import Foundation

extension OpenCodeACPProvider {
  public func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    try validate(request: request, installation: installation)
    let runDirectory = try makeRunDirectory(prefix: "run")
    var client: OpenCodeACPClient?

    do {
      let persistentStateDirectory = try makePersistentStateDirectory(
        installation: installation,
        request: request
      )
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        projectRoot: request.projectRoot,
        runDirectory: runDirectory,
        persistentStateDirectory: persistentStateDirectory,
        networkAllowed: request.networkAccessRequested,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      _ = try validate(initialization)
      let capabilities = capabilities(initialization)
      try require(request.requiredCapabilities, from: capabilities)

      let session = try await session(
        for: request,
        projectRoot: launch.process.workingDirectory,
        initialization: initialization,
        client: connected
      )
      let mode = try Self.modeValue(
        for: request.mutationIntent,
        in: session
      )
      var configOptions = try await connected.setSessionConfigOption(
        sessionID: session.id,
        configID: "mode",
        value: mode
      )
      if let requestedModel = request.model {
        let model = try Self.resolveModel(requestedModel, from: session)
        configOptions = try await connected.setSessionConfigOption(
          sessionID: session.id,
          configID: "model",
          value: model
        )
      } else if request.effort != nil,
        let model = Self.availableCurrentModelID(in: session)
      {
        configOptions = try await connected.setSessionConfigOption(
          sessionID: session.id,
          configID: "model",
          value: model
        )
      }
      let hasEffortOption = configOptions.contains {
        $0.id == "effort" && !$0.values.isEmpty
      }
      if let requestedEffort = request.effort {
        guard let option = configOptions.first(where: { $0.id == "effort" }) else {
          throw AgentRuntimeError.capabilityUnavailable(.effortSelection)
        }
        guard option.values.contains(where: { $0.value == requestedEffort }) else {
          throw AgentRuntimeError.invalidRequest("request.effort")
        }
        configOptions = try await connected.setSessionConfigOption(
          sessionID: session.id,
          configID: "effort",
          value: requestedEffort
        )
      }
      var effectiveCapabilities = capabilities
      if hasEffortOption {
        effectiveCapabilities = AgentCapabilitySnapshot(
          advertised: capabilities.advertised.union([.effortSelection]),
          observed: capabilities.observed.union([.effortSelection]),
          enforced: capabilities.enforced.union([.effortSelection])
        )
      }
      let binding = try AgentBinding(
        providerID: .openCode,
        installationID: installation.id,
        providerSessionID: session.id,
        providerRunID: UUID().uuidString.lowercased()
      )
      let normalizer = OpenCodeACPEventNormalizer(
        taskID: request.taskID,
        binding: binding,
        projectRoot: launch.process.workingDirectory
      )
      let initialSequence = await connected.eventSequence
      let execution = OpenCodeACPExecution(
        client: connected,
        normalizer: normalizer,
        sessionID: session.id,
        prompt: request.prompt,
        initialClientEventSequence: initialSequence,
        inactivityTimeout: configuration.inactivityTimeout,
        eventBufferLimit: configuration.eventBufferLimit,
        cleanup: {
          OpenCodeACPLaunchBuilder.removeRunDirectory(launch.runDirectory)
        }
      )
      await execution.start()

      return AgentExecutionHandle(
        taskID: request.taskID,
        binding: binding,
        capabilities: effectiveCapabilities,
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
      OpenCodeACPLaunchBuilder.removeRunDirectory(runDirectory)
      throw Self.runtimeError(for: error)
    }
  }

  func makeClient(transport: any OpenCodeACPTransport) -> OpenCodeACPClient {
    OpenCodeACPClient(
      transport: transport,
      clientInfo: configuration.clientInfo,
      requestTimeout: configuration.requestTimeout,
      eventBufferLimit: configuration.eventBufferLimit
    )
  }

  private func validate(
    request: AgentExecutionRequest,
    installation: AgentInstallation
  ) throws {
    guard installation.providerID == .openCode else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    guard !request.networkAccessRequested else {
      throw AgentRuntimeError.invalidRequest("request.networkAccessRequested")
    }
    guard
      request.workspaceStrategy == .sharedProject
        || request.workspaceStrategy == .exclusiveProject
    else {
      throw AgentRuntimeError.invalidRequest("request.workspaceStrategy")
    }
    guard request.profileID == nil || request.profileID == OpenCodeACPProfiles.controlledReadOnly
    else {
      throw AgentRuntimeError.invalidRequest("request.profileID")
    }
    if let model = request.model {
      guard !model.isEmpty, model.utf8.count <= 256,
        !model.contains("\0"),
        model.rangeOfCharacter(from: .controlCharacters) == nil
      else {
        throw AgentRuntimeError.invalidRequest("request.model")
      }
    }
  }

  private func session(
    for request: AgentExecutionRequest,
    projectRoot: String,
    initialization: OpenCodeACPInitialization,
    client: OpenCodeACPClient
  ) async throws -> OpenCodeACPSession {
    guard let requestedSessionID = request.requestedSessionID else {
      return try await client.newSession(cwd: projectRoot)
    }
    if initialization.supportsResumeSession {
      return try await client.resumeSession(id: requestedSessionID, cwd: projectRoot)
    }
    if initialization.supportsLoadSession {
      return try await client.loadSession(id: requestedSessionID, cwd: projectRoot)
    }
    throw AgentRuntimeError.capabilityUnavailable(.sessionContinue)
  }
}
