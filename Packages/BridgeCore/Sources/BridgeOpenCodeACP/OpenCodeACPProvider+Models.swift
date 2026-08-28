import BridgeAgentCore
import Foundation

extension OpenCodeACPProvider {
  public func models(
    installation: AgentInstallation,
    projectRoot: String?
  ) async throws -> [AgentModelDescriptor] {
    try await models(
      installation: installation,
      projectRoot: projectRoot,
      selectedModelID: nil
    )
  }

  public func models(
    installation: AgentInstallation,
    projectRoot: String?,
    selectedModelID: String?
  ) async throws -> [AgentModelDescriptor] {
    guard installation.providerID == .openCode else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let probeRoot = try makeProbeRoot(projectRoot)
    let runDirectory: String
    do {
      runDirectory = try makeRunDirectory(prefix: "models-run")
    } catch {
      cleanup(runDirectory: nil, probeRoot: probeRoot)
      throw error
    }
    var client: OpenCodeACPClient?
    do {
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        projectRoot: probeRoot.path,
        runDirectory: runDirectory,
        networkAllowed: false,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      _ = try validate(initialization)
      let session = try await connected.newSession(cwd: launch.process.workingDirectory)
      let options: [OpenCodeACPConfigOption]
      let selectedModel: String?
      if let selectedModelID {
        let model = try Self.resolveModel(selectedModelID, from: session)
        options = try await connected.setSessionConfigOption(
          sessionID: session.id,
          configID: "model",
          value: model
        )
        selectedModel = model
      } else if let currentModel = Self.availableCurrentModelID(in: session) {
        options = try await connected.setSessionConfigOption(
          sessionID: session.id,
          configID: "model",
          value: currentModel
        )
        selectedModel = currentModel
      } else {
        options = session.configOptions
        selectedModel = nil
      }
      let models = try Self.modelDescriptors(
        from: options,
        selectedModelID: selectedModel
      )
      await connected.shutdown()
      cleanup(runDirectory: launch.runDirectory, probeRoot: probeRoot)
      return models
    } catch {
      await client?.shutdown()
      cleanup(runDirectory: runDirectory, probeRoot: probeRoot)
      throw Self.runtimeError(for: error)
    }
  }

  func capabilities(
    _ initialization: OpenCodeACPInitialization
  ) -> AgentCapabilitySnapshot {
    var supported: Set<AgentCapability> = [
      .sessionCreate,
      .interrupt,
      .steer,
      .textDelta,
      .reasoningDelta,
      .toolLifecycle,
      .plan,
      .usage,
      .workspaceRead,
      .workspaceWriteInPlace,
      .oneShotApproval,
      .profileSelection,
      .modelSelection,
    ]
    if initialization.supportsLoadSession || initialization.supportsResumeSession {
      supported.insert(.sessionContinue)
    }
    return AgentCapabilitySnapshot(
      advertised: supported,
      observed: supported,
      enforced: supported
    )
  }

  static func modelDescriptors(
    from options: [OpenCodeACPConfigOption],
    selectedModelID: String? = nil
  ) throws -> [AgentModelDescriptor] {
    guard let option = options.first(where: { $0.id == "model" }) else {
      throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
    }
    let selected = selectedModelID ?? option.currentValue
    let effort = options.first(where: { $0.id == "effort" })
    return try option.values.map {
      try AgentModelDescriptor(
        id: $0.value,
        displayName: $0.name,
        supportedReasoningEfforts: $0.value == selected
          ? effort?.values.map(\.value) ?? [] : [],
        defaultReasoningEffort: $0.value == selected ? effort?.currentValue : nil
      )
    }
  }

  static func modelDescriptors(from session: OpenCodeACPSession) throws
    -> [AgentModelDescriptor]
  {
    try modelDescriptors(from: session.configOptions)
  }

  private static func currentModelID(in session: OpenCodeACPSession) -> String? {
    session.configOptions.first(where: { $0.id == "model" })?.currentValue
  }

  static func availableCurrentModelID(in session: OpenCodeACPSession) -> String? {
    guard let option = session.configOptions.first(where: { $0.id == "model" }),
      let currentValue = option.currentValue,
      option.values.contains(where: { $0.value == currentValue })
    else { return nil }
    return currentValue
  }

  static func modeValue(
    for mutationIntent: AgentMutationIntent,
    in session: OpenCodeACPSession
  ) throws -> String {
    let expected = mutationIntent == .readOnly ? "plan" : "build"
    guard let option = session.configOptions.first(where: { $0.id == "mode" }),
      option.values.contains(where: { $0.value == expected })
    else {
      throw AgentRuntimeError.capabilityUnavailable(
        mutationIntent == .readOnly ? .workspaceRead : .workspaceWriteInPlace
      )
    }
    return expected
  }

  static func resolveModel(
    _ requested: String,
    from session: OpenCodeACPSession
  ) throws -> String {
    let models = try modelDescriptors(from: session)
    if models.contains(where: { $0.id == requested }) { return requested }
    throw AgentRuntimeError.modelUnavailable(requested)
  }

  func require(
    _ required: Set<AgentCapability>,
    from snapshot: AgentCapabilitySnapshot
  ) throws {
    guard
      let missing = required.subtracting(snapshot.effective)
        .sorted(by: { $0.rawValue < $1.rawValue })
        .first
    else { return }
    throw AgentRuntimeError.capabilityUnavailable(missing)
  }
}
