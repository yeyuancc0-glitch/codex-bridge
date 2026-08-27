import BridgeACP
import BridgeAgentCore
import BridgeDomain
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct DeepSeekHarnessACPProviderConfiguration: Sendable {
  public let clientInfo: DeepSeekHarnessACPClientInfo
  public let launchBuilder: DeepSeekHarnessACPLaunchBuilder
  public let requestTimeout: Duration
  public let inactivityTimeout: Duration
  public let eventBufferLimit: Int
  public let runtimeBaseDirectory: String
  public let sourceEnvironment: [String: String]
  public let transportFactory: DeepSeekHarnessACPTransportFactory

  public init(
    clientInfo: DeepSeekHarnessACPClientInfo = .init(
      name: "codex-bridge",
      title: "Codex Bridge",
      version: "1"
    ),
    launchBuilder: DeepSeekHarnessACPLaunchBuilder? = nil,
    requestTimeout: Duration = DeepSeekHarnessACPConstants.requestTimeout,
    inactivityTimeout: Duration = DeepSeekHarnessACPConstants.inactivityTimeout,
    eventBufferLimit: Int = DeepSeekHarnessACPConstants.maximumEventBuffer,
    runtimeBaseDirectory: String = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBridge/DeepSeekHarnessACP", isDirectory: true).path,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    transportFactory: @escaping DeepSeekHarnessACPTransportFactory = { launch in
      try ACPProcessTransport.launch(configuration: launch.process)
    }
  ) throws {
    self.clientInfo = clientInfo
    self.launchBuilder = try launchBuilder ?? DeepSeekHarnessACPLaunchBuilder()
    self.requestTimeout = requestTimeout
    self.inactivityTimeout = inactivityTimeout
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.transportFactory = transportFactory
  }
}

public struct DeepSeekHarnessACPProvider: AgentProvider, Sendable {
  public let descriptor: AgentProviderDescriptor

  private let configuration: DeepSeekHarnessACPProviderConfiguration

  public init(configuration: DeepSeekHarnessACPProviderConfiguration? = nil) throws {
    self.configuration = try configuration ?? DeepSeekHarnessACPProviderConfiguration()
    descriptor = try AgentProviderDescriptor(
      providerID: .deepSeekHarness,
      displayName: "DeepSeek Harness",
      adapterRevision: 1
    )
  }

  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard request.installation.providerID == .deepSeekHarness else {
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
    var client: DeepSeekHarnessACPClient?
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
      try validate(initialization)
      _ = try await connected.newSession(cwd: probeRoot.path)
      await connected.shutdown()
      cleanup(runDirectory: launch.runDirectory, probeRoot: probeRoot)
      let installation = try AgentInstallation(
        id: request.installation.id,
        providerID: .deepSeekHarness,
        executablePath: launch.resolvedExecutablePath,
        version: DeepSeekHarnessACPConstants.releaseVersion,
        protocolRevision: String(DeepSeekHarnessACPConstants.acpProtocolVersion),
        artifacts: request.installation.artifacts
      )
      return AgentProbeResult(
        installation: installation,
        available: true,
        capabilities: Self.capabilitySnapshot
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
    var client: DeepSeekHarnessACPClient?
    do {
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        projectRoot: request.projectRoot,
        runDirectory: runDirectory,
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
        binding: binding
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
          shutdown: { await execution.shutdown() }
        )
      )
    } catch {
      await client?.shutdown()
      DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(runDirectory)
      throw Self.runtimeError(for: error)
    }
  }

  public static let capabilitySnapshot = AgentCapabilitySnapshot(
    advertised: [
      .sessionCreate,
      .interrupt,
      .textDelta,
      .workspaceRead,
      .oneShotApproval,
    ],
    observed: [
      .sessionCreate,
      .interrupt,
      .textDelta,
      .workspaceRead,
      .oneShotApproval,
    ],
    enforced: [
      .sessionCreate,
      .interrupt,
      .textDelta,
      .workspaceRead,
    ]
  )

  private func makeClient(transport: any ACPTransport) -> DeepSeekHarnessACPClient {
    DeepSeekHarnessACPClient(
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
    guard installation.providerID == .deepSeekHarness else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    guard request.mutationIntent == .readOnly else {
      throw AgentRuntimeError.invalidRequest("request.mutationIntent")
    }
    guard request.workspaceStrategy == .sharedProject else {
      throw AgentRuntimeError.invalidRequest("request.workspaceStrategy")
    }
    guard !request.networkAccessRequested else {
      throw AgentRuntimeError.invalidRequest("request.networkAccessRequested")
    }
    guard request.requestedSessionID == nil else {
      throw AgentRuntimeError.capabilityUnavailable(.sessionContinue)
    }
    guard request.model == nil else {
      throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
    }
    guard request.effort == nil else {
      throw AgentRuntimeError.capabilityUnavailable(.effortSelection)
    }
    guard
      request.profileID == nil || request.profileID == DeepSeekHarnessACPProfiles.controlledReadOnly
    else {
      throw AgentRuntimeError.capabilityUnavailable(.profileSelection)
    }
  }

  func validate(_ initialization: DeepSeekHarnessACPInitialization) throws {
    guard initialization.protocolVersion == DeepSeekHarnessACPConstants.acpProtocolVersion else {
      throw AgentRuntimeError.unsupportedProtocol(String(initialization.protocolVersion))
    }
    guard initialization.agentName != nil || initialization.agentVersion != nil else { return }
    guard initialization.agentName == DeepSeekHarnessACPConstants.agentName,
      initialization.agentVersion == DeepSeekHarnessACPConstants.agentVersion
    else {
      throw AgentRuntimeError.unsupportedProtocol("unexpected_deepseek_harness_identity")
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

  private static func probeReason(_ error: any Error) -> String {
    switch error {
    case DeepSeekHarnessACPError.templateMismatch:
      return "DeepSeek Harness configuration does not match the managed read-only template."
    case DeepSeekHarnessACPError.nodeVersionIncompatible(let version):
      return
        "DeepSeek Harness requires Node \(DeepSeekHarnessACPConstants.nodeRequirement); found \(version)."
    case AgentRuntimeError.unsupportedProtocol(let value):
      return "DeepSeek Harness ACP identity or protocol is incompatible: \(value)."
    case DeepSeekHarnessACPError.unsupportedProtocol(let value):
      return "DeepSeek Harness ACP uses unsupported protocol version \(value)."
    case DeepSeekHarnessACPError.processExited(let code):
      return
        "DeepSeek Harness ACP exited during probe (code: \(code.map(String.init) ?? "unknown"))."
    case DeepSeekHarnessACPError.artifactInvalid:
      return "DeepSeek Harness installation artifacts are unavailable or changed."
    default:
      return "DeepSeek Harness ACP probe failed."
    }
  }

  private static func requiresReview(_ error: any Error) -> Bool {
    switch error {
    case DeepSeekHarnessACPError.artifactInvalid,
      DeepSeekHarnessACPError.templateMismatch,
      DeepSeekHarnessACPError.nodeVersionIncompatible,
      AgentRuntimeError.unsupportedProtocol:
      return true
    default:
      return false
    }
  }

  private static func runtimeError(for error: any Error) -> AgentRuntimeError {
    if let error = error as? AgentRuntimeError { return error }
    switch error {
    case DeepSeekHarnessACPError.requestTimedOut,
      DeepSeekHarnessACPError.inactivityTimeout:
      return .timedOut
    case DeepSeekHarnessACPError.processExited(let code):
      return .processExited(code)
    case DeepSeekHarnessACPError.oversizedFrame:
      return .oversizedFrame
    case DeepSeekHarnessACPError.sessionMismatch:
      return .sessionMismatch
    case DeepSeekHarnessACPError.invalidMessage,
      DeepSeekHarnessACPError.malformedResponse,
      DeepSeekHarnessACPError.malformedPermission:
      return .malformedEvent("deepseek-harness-acp")
    case DeepSeekHarnessACPError.remote(let code, _):
      return .malformedEvent("deepseek-harness-acp-remote-\(code)")
    case DeepSeekHarnessACPError.transportClosed:
      return .processUnavailable
    case DeepSeekHarnessACPError.unsupportedProtocol(let version):
      return .unsupportedProtocol("deepseek-harness-acp-v\(version)")
    default:
      return .processUnavailable
    }
  }

  private func makeRunDirectory(prefix: String) throws -> String {
    guard !prefix.isEmpty,
      prefix.utf8.count <= 64,
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
      guard chmod(path, 0o700) == 0 else { throw AgentRuntimeError.processUnavailable }
      try Self.validatePrivateDirectory(path)
      return URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
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
      DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(runDirectory)
    }
    if probeRoot.owned {
      DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(probeRoot.path)
    }
  }

  private func prepareRuntimeBase() throws -> String {
    let value = configuration.runtimeBaseDirectory
    guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest("runtimeBaseDirectory")
    }
    let path = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(path, 0o700) == 0 else { throw AgentRuntimeError.processUnavailable }
      try Self.validatePrivateDirectory(path)
      return URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
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
}

private struct ProbeRoot: Sendable {
  let path: String
  let owned: Bool
}
