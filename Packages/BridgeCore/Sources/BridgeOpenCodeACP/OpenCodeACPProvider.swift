import BridgeAgentCore
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
  public let eventBufferLimit: Int
  public let runtimeBaseDirectory: String
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
    eventBufferLimit: Int = 256,
    runtimeBaseDirectory: String = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBridge/OpenCodeACP", isDirectory: true).path,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    transportFactory: @escaping OpenCodeACPTransportFactory = { launch in
      try OpenCodeACPProcessTransport.launch(configuration: launch.process)
    }
  ) {
    self.clientInfo = clientInfo
    self.compatibility = compatibility
    self.launchBuilder = launchBuilder
    self.requestTimeout = requestTimeout
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.runtimeBaseDirectory = runtimeBaseDirectory
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

  public func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    try validate(request: request, installation: installation)
    let runDirectory = try makeRunDirectory(prefix: "run")
    var client: OpenCodeACPClient?

    do {
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        projectRoot: request.projectRoot,
        runDirectory: runDirectory,
        networkAllowed: request.networkAccessRequested,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      _ = try validate(initialization)
      let capabilities = capabilities(initialization)
      try require(request.requiredCapabilities, from: capabilities)

      let sessionID = try await sessionID(
        for: request,
        projectRoot: launch.process.workingDirectory,
        initialization: initialization,
        client: connected
      )
      let binding = try AgentBinding(
        providerID: .openCode,
        installationID: installation.id,
        providerSessionID: sessionID,
        providerRunID: UUID().uuidString.lowercased()
      )
      let normalizer = OpenCodeACPEventNormalizer(taskID: request.taskID, binding: binding)
      let initialSequence = await connected.eventSequence
      let execution = OpenCodeACPExecution(
        client: connected,
        normalizer: normalizer,
        sessionID: sessionID,
        prompt: request.prompt,
        initialClientEventSequence: initialSequence,
        eventBufferLimit: configuration.eventBufferLimit,
        cleanup: {
          OpenCodeACPLaunchBuilder.removeRunDirectory(launch.runDirectory)
        }
      )
      await execution.start()

      return AgentExecutionHandle(
        taskID: request.taskID,
        binding: binding,
        capabilities: capabilities,
        events: execution.events,
        control: AgentExecutionControl(
          interrupt: { try await execution.interrupt() }
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
    guard request.mutationIntent == .readOnly else {
      throw AgentRuntimeError.capabilityUnavailable(.workspaceWriteInPlace)
    }
    guard request.workspaceStrategy == .sharedProject else {
      throw AgentRuntimeError.invalidRequest("request.workspaceStrategy")
    }
    guard request.profileID == nil || request.profileID == OpenCodeACPProfiles.controlledReadOnly
    else {
      throw AgentRuntimeError.invalidRequest("request.profileID")
    }
    if request.model != nil {
      throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
    }
    if request.effort != nil {
      throw AgentRuntimeError.capabilityUnavailable(.effortSelection)
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

  private func sessionID(
    for request: AgentExecutionRequest,
    projectRoot: String,
    initialization: OpenCodeACPInitialization,
    client: OpenCodeACPClient
  ) async throws -> String {
    guard let requestedSessionID = request.requestedSessionID else {
      return try await client.newSession(cwd: projectRoot).id
    }
    if initialization.supportsResumeSession {
      try await client.resumeSession(id: requestedSessionID, cwd: projectRoot)
      return requestedSessionID
    }
    if initialization.supportsLoadSession {
      try await client.loadSession(id: requestedSessionID, cwd: projectRoot)
      return requestedSessionID
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
      .textDelta,
      .reasoningDelta,
      .toolLifecycle,
      .plan,
      .usage,
      .workspaceRead,
      .profileSelection,
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
    switch error {
    case OpenCodeACPError.unsupportedProtocol(let version):
      return "OpenCode uses unsupported ACP protocol version \(version)."
    case AgentRuntimeError.unsupportedProtocol(let value):
      return "OpenCode version or identity is incompatible: \(value)."
    case AgentRuntimeError.installationUnavailable:
      return "OpenCode executable is unavailable or unsafe."
    case AgentRuntimeError.processUnavailable:
      return "The required local process or read-only sandbox is unavailable."
    case OpenCodeACPError.requestTimedOut:
      return "OpenCode ACP initialization timed out."
    case OpenCodeACPError.processExited(let code):
      let value = code.map { String($0) } ?? "unknown"
      return "OpenCode ACP exited during initialization (code: \(value))."
    default:
      return "OpenCode ACP probe failed."
    }
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
    case .remote, .transportClosed:
      return .processUnavailable
    }
  }
}

private struct ProbeRoot: Sendable {
  let path: String
  let owned: Bool
}
