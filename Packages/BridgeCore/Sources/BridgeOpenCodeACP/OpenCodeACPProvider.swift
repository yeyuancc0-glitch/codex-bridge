import BridgeAgentCore
import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public typealias OpenCodeACPTransportFactory =
  @Sendable (
    OpenCodeACPLaunchConfiguration
  ) throws -> any OpenCodeACPTransport

public struct OpenCodeACPProviderConfiguration: Sendable {
  public let clientInfo: OpenCodeACPClientInfo
  public let compatibility: OpenCodeACPCompatibility
  public let launchBuilder: OpenCodeACPLaunchBuilder
  public let requestTimeout: Duration
  public let inactivityTimeout: Duration
  public let eventBufferLimit: Int
  public let runtimeBaseDirectory: String
  public let persistentStateBaseDirectory: String?
  public let sourceEnvironment: [String: String]
  public let transportFactory: OpenCodeACPTransportFactory

  public init(
    clientInfo: OpenCodeACPClientInfo = .init(
      name: "codex-bridge",
      title: "Codex Bridge",
      version: "1"
    ),
    compatibility: OpenCodeACPCompatibility = .init(),
    launchBuilder: OpenCodeACPLaunchBuilder = .init(),
    requestTimeout: Duration = .seconds(30),
    inactivityTimeout: Duration = .seconds(10 * 60),
    eventBufferLimit: Int = 256,
    runtimeBaseDirectory: String = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBridge/OpenCodeACP", isDirectory: true).path,
    persistentStateBaseDirectory: String? = nil,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    transportFactory: @escaping OpenCodeACPTransportFactory = { launch in
      try OpenCodeACPProcessTransport.launch(configuration: launch.process)
    }
  ) {
    self.clientInfo = clientInfo
    self.compatibility = compatibility
    self.launchBuilder = launchBuilder
    self.requestTimeout = requestTimeout
    self.inactivityTimeout = inactivityTimeout
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.persistentStateBaseDirectory = persistentStateBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.transportFactory = transportFactory
  }
}

public struct OpenCodeACPProvider: AgentProvider, Sendable {
  public let descriptor: AgentProviderDescriptor

  private let configuration: OpenCodeACPProviderConfiguration

  public init(configuration: OpenCodeACPProviderConfiguration = .init()) throws {
    self.configuration = configuration
    descriptor = try AgentProviderDescriptor(
      providerID: .openCode,
      displayName: "OpenCode",
      adapterRevision: 1
    )
  }

  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard request.installation.providerID == .openCode else {
      return unavailableProbe(
        request.installation,
        reason: "Installation belongs to another provider."
      )
    }

    let probeRoot: ProbeRoot
    do {
      probeRoot = try makeProbeRoot(request.projectRoot)
    } catch {
      return unavailableProbe(request.installation, reason: "Probe workspace is unavailable.")
    }
    let runDirectory: String
    do {
      runDirectory = try makeRunDirectory(prefix: "probe-run")
    } catch {
      cleanup(runDirectory: nil, probeRoot: probeRoot)
      return unavailableProbe(request.installation, reason: "Probe runtime is unavailable.")
    }
    var client: OpenCodeACPClient?

    do {
      let launch = try configuration.launchBuilder.make(
        installation: request.installation,
        projectRoot: probeRoot.path,
        runDirectory: runDirectory,
        networkAllowed: false,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      let version = try validate(initialization)
      let installation = try AgentInstallation(
        id: request.installation.id,
        providerID: .openCode,
        executablePath: launch.resolvedExecutablePath,
        version: version,
        protocolRevision: String(initialization.protocolVersion)
      )
      let capabilities = capabilities(initialization)
      await connected.shutdown()
      cleanup(runDirectory: launch.runDirectory, probeRoot: probeRoot)
      return AgentProbeResult(
        installation: installation,
        available: true,
        capabilities: capabilities
      )
    } catch {
      await client?.shutdown()
      cleanup(runDirectory: runDirectory, probeRoot: probeRoot)
      return unavailableProbe(
        request.installation,
        reason: Self.probeReason(error),
        reviewRequired: Self.requiresReview(error)
      )
    }
  }

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
      let modelToSelect = selectedModelID ?? Self.currentModelID(in: session)
      if let modelToSelect {
        let model = try Self.resolveModel(modelToSelect, from: session)
        options = try await connected.setSessionConfigOption(
          sessionID: session.id,
          configID: "model",
          value: model
        )
        selectedModel = model
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
      } else if request.effort != nil, let model = Self.currentModelID(in: session) {
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

  private func makeClient(transport: any OpenCodeACPTransport) -> OpenCodeACPClient {
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

  private func validate(_ initialization: OpenCodeACPInitialization) throws -> String {
    guard initialization.protocolVersion == 1 else {
      throw AgentRuntimeError.unsupportedProtocol(String(initialization.protocolVersion))
    }
    guard initialization.agentName?.caseInsensitiveCompare("OpenCode") == .orderedSame else {
      throw AgentRuntimeError.unsupportedProtocol("unexpected_agent")
    }
    guard let version = initialization.agentVersion,
      configuration.compatibility.accepts(version: version)
    else {
      throw AgentRuntimeError.unsupportedProtocol(
        initialization.agentVersion ?? "missing_opencode_version"
      )
    }
    return version
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

  private func unavailableProbe(
    _ installation: AgentInstallation,
    reason: String,
    reviewRequired: Bool = false
  ) -> AgentProbeResult {
    AgentProbeResult(
      installation: installation,
      available: false,
      reviewRequired: reviewRequired,
      capabilities: .empty,
      unavailableReason: reason
    )
  }

  private func capabilities(
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

  private static func modelDescriptors(
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

  private static func modelDescriptors(from session: OpenCodeACPSession) throws
    -> [AgentModelDescriptor]
  {
    try modelDescriptors(from: session.configOptions)
  }

  private static func currentModelID(in session: OpenCodeACPSession) -> String? {
    session.configOptions.first(where: { $0.id == "model" })?.currentValue
  }

  private static func modeValue(
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

  private static func resolveModel(
    _ requested: String,
    from session: OpenCodeACPSession
  ) throws -> String {
    let models = try modelDescriptors(from: session)
    if models.contains(where: { $0.id == requested }) { return requested }
    throw AgentRuntimeError.modelUnavailable(requested)
  }

  private func require(
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

  private func makeRunDirectory(prefix: String) throws -> String {
    guard !prefix.isEmpty, prefix.utf8.count <= 64,
      prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else {
      throw AgentRuntimeError.invalidRequest("runtime.prefix")
    }
    let base = try prepareRuntimeBase()
    let path = URL(fileURLWithPath: base, isDirectory: true)
      .appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
      .path
    do {
      try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(path, 0o700) == 0 else {
        throw AgentRuntimeError.processUnavailable
      }
      try Self.validatePrivateDirectory(path)
      return URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  private func makeProbeRoot(_ requested: String?) throws -> ProbeRoot {
    if let requested {
      return ProbeRoot(path: requested, owned: false)
    }
    let path = try makeRunDirectory(prefix: "probe-project")
    return ProbeRoot(path: path, owned: true)
  }

  private func cleanup(runDirectory: String?, probeRoot: ProbeRoot) {
    if let runDirectory {
      OpenCodeACPLaunchBuilder.removeRunDirectory(runDirectory)
    }
    if probeRoot.owned {
      OpenCodeACPLaunchBuilder.removeRunDirectory(probeRoot.path)
    }
  }

  private func prepareRuntimeBase() throws -> String {
    let value = configuration.runtimeBaseDirectory
    guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest("runtimeBaseDirectory")
    }
    let requested = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: requested,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let canonical = URL(fileURLWithPath: requested, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
      guard chmod(canonical, 0o700) == 0 else {
        throw AgentRuntimeError.processUnavailable
      }
      try Self.validatePrivateDirectory(canonical)
      return canonical
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  private func makePersistentStateDirectory(
    installation: AgentInstallation,
    request: AgentExecutionRequest
  ) throws -> String? {
    guard let configuredBase = configuration.persistentStateBaseDirectory else { return nil }
    let base = try preparePrivateDirectory(
      configuredBase,
      field: "persistentStateBaseDirectory"
    )
    let identity = [
      installation.providerID.rawValue,
      installation.id.rawValue,
      request.projectID.rawValue,
      request.projectRoot,
    ].joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }
      .joined()
    return try preparePrivateDirectory(
      URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent(digest, isDirectory: true).path,
      field: "persistentStateDirectory"
    )
  }

  private func preparePrivateDirectory(_ value: String, field: String) throws -> String {
    guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    let requested = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: requested,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(requested, 0o700) == 0 else { throw AgentRuntimeError.processUnavailable }
      try Self.validatePrivateDirectory(requested)
      let canonical = URL(fileURLWithPath: requested, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL.path
      return canonical
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  private static func validatePrivateDirectory(_ path: String) throws {
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
      metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o777 == 0o700
    else {
      throw AgentRuntimeError.processUnavailable
    }
  }

  private static func probeReason(_ error: any Error) -> String {
    let base: String
    switch error {
    case OpenCodeACPError.unsupportedProtocol(let version):
      base = "OpenCode uses unsupported ACP protocol version \(version)."
    case AgentRuntimeError.unsupportedProtocol(let value):
      base = "OpenCode version or identity is incompatible: \(value)."
    case AgentRuntimeError.installationUnavailable:
      base = "OpenCode executable is unavailable or unsafe."
    case AgentRuntimeError.processUnavailable:
      base = "The required local process or read-only sandbox is unavailable."
    case AgentRuntimeError.modelUnavailable(let model):
      base = "The selected OpenCode model is unavailable: \(model)."
    case OpenCodeACPError.requestTimedOut:
      base = "OpenCode ACP initialization timed out."
    case OpenCodeACPError.processExited(let code):
      let value = code.map { String($0) } ?? "unknown"
      base = "OpenCode ACP exited during initialization (code: \(value))."
    default:
      base = "OpenCode ACP probe failed."
    }
    let detail = String(describing: error)
    if detail == base || detail.isEmpty { return base }
    let truncated = detail.prefix(300)
    return "\(base) (\(truncated))"
  }

  private static func requiresReview(_ error: any Error) -> Bool {
    switch error {
    case OpenCodeACPError.unsupportedProtocol,
      AgentRuntimeError.unsupportedProtocol:
      return true
    default:
      return false
    }
  }

  private static func runtimeError(for error: any Error) -> AgentRuntimeError {
    if let error = error as? AgentRuntimeError { return error }
    guard let error = error as? OpenCodeACPError else {
      return .processUnavailable
    }
    switch error {
    case .notInitialized, .operationInProgress:
      return .processUnavailable
    case .unsupportedProtocol(let version):
      return .unsupportedProtocol("opencode-acp-v\(version)")
    case .requestTimedOut:
      return .timedOut
    case .processExited(let code):
      return .processExited(code)
    case .oversizedFrame:
      return .oversizedFrame
    case .sessionMismatch:
      return .sessionMismatch
    case .invalidMessage, .malformedResponse:
      return .malformedEvent("opencode-acp")
    case .remote(let code, let message):
      if code == -32602, message.localizedCaseInsensitiveContains("model") {
        return .modelUnavailable(String(message.prefix(256)))
      }
      return .malformedEvent("opencode-acp-remote-\(code)")
    case .transportClosed:
      return .processUnavailable
    }
  }
}

private struct ProbeRoot: Sendable {
  let path: String
  let owned: Bool
}
