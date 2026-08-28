import BridgeAgentCore
import BridgeProcess
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct AntigravityCLIProviderConfiguration: Sendable {
  public let compatibility: AntigravityCLICompatibility
  public let launchBuilder: AntigravityCLILaunchBuilder
  public let commandRunner: any AntigravityCLICommandRunning
  public let requestTimeout: Duration
  public let inactivityTimeout: Duration
  public let eventBufferLimit: Int
  public let runtimeBaseDirectory: String
  public let sourceEnvironment: [String: String]
  public let transportFactory: AntigravityCLITransportFactory

  public init(
    compatibility: AntigravityCLICompatibility = .init(),
    launchBuilder: AntigravityCLILaunchBuilder = .init(),
    commandRunner: any AntigravityCLICommandRunning = AntigravityCLICommandRunner(),
    requestTimeout: Duration = .seconds(30),
    inactivityTimeout: Duration = .seconds(10 * 60),
    eventBufferLimit: Int = 256,
    runtimeBaseDirectory: String = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBridge/AntigravityCLI", isDirectory: true).path,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    transportFactory: @escaping AntigravityCLITransportFactory = { launch in
      try AntigravityCLIProcessTransport.launch(configuration: launch.process)
    }
  ) {
    self.compatibility = compatibility
    self.launchBuilder = launchBuilder
    self.commandRunner = commandRunner
    self.requestTimeout = requestTimeout
    self.inactivityTimeout = inactivityTimeout
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.transportFactory = transportFactory
  }
}

public struct AntigravityCLIProvider: AgentProvider, Sendable {
  public let descriptor: AgentProviderDescriptor

  private let configuration: AntigravityCLIProviderConfiguration

  public init(configuration: AntigravityCLIProviderConfiguration = .init()) throws {
    self.configuration = configuration
    descriptor = try AgentProviderDescriptor(
      providerID: .antigravity,
      displayName: "Antigravity CLI",
      adapterRevision: 2
    )
  }

  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard request.installation.providerID == .antigravity else {
      return unavailableProbe(
        request.installation,
        reason: "Installation belongs to another provider."
      )
    }
    guard
      FileManager.default.isExecutableFile(
        atPath: configuration.launchBuilder.sandboxExecutablePath
      )
    else {
      return unavailableProbe(
        request.installation,
        reason: "The macOS read-only process boundary is unavailable."
      )
    }

    do {
      let resolved = try Self.resolvedExecutable(request.installation.executablePath)
      let environment = try configuration.launchBuilder.commandEnvironment(
        executablePath: resolved,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let result = try await configuration.commandRunner.run(
        argv: [resolved, "--version"],
        workingDirectory: request.projectRoot,
        environment: environment,
        timeout: configuration.requestTimeout
      )
      guard !result.timedOut else { throw AntigravityCLIError.requestTimedOut }
      guard Self.succeeded(result.termination) else {
        throw Self.processError(result.termination)
      }
      let output = result.standardOutput.tail + "\n" + result.standardError.tail
      guard let version = AntigravityCLISemanticVersion(output) else {
        throw AntigravityCLIError.unsupportedVersion("unrecognized")
      }
      guard configuration.compatibility.accepts(version) else {
        throw AntigravityCLIError.unsupportedVersion(version.stringValue)
      }
      let help = try await configuration.commandRunner.run(
        argv: [resolved, "--help"],
        workingDirectory: request.projectRoot,
        environment: environment,
        timeout: configuration.requestTimeout
      )
      guard !help.timedOut else { throw AntigravityCLIError.requestTimedOut }
      guard Self.succeeded(help.termination) else {
        throw Self.processError(help.termination)
      }
      guard !help.standardOutput.truncated, !help.standardError.truncated else {
        throw AgentRuntimeError.unsupportedProtocol("antigravity-help-output")
      }
      let facts = AntigravityCLIHelpFacts.parse(
        help.standardOutput.tail + "\n" + help.standardError.tail
      )
      guard facts.supportsStreamJSON, facts.supportsPlanMode else {
        throw AgentRuntimeError.unsupportedProtocol("antigravity-stream-json-plan")
      }
      let installation = try AgentInstallation(
        id: request.installation.id,
        providerID: .antigravity,
        executablePath: resolved,
        version: version.stringValue,
        protocolRevision: "stream-json-v1"
      )
      return AgentProbeResult(
        installation: installation,
        available: true,
        capabilities: Self.capabilities(observed: facts.observedCapabilities)
      )
    } catch {
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
    guard installation.providerID == .antigravity else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let resolved = try Self.resolvedExecutable(installation.executablePath)
    let environment = try configuration.launchBuilder.commandEnvironment(
      executablePath: resolved,
      sourceEnvironment: configuration.sourceEnvironment
    )
    let result = try await configuration.commandRunner.run(
      argv: [resolved, "models"],
      workingDirectory: projectRoot,
      environment: environment,
      timeout: configuration.requestTimeout
    )
    guard !result.timedOut else { throw AgentRuntimeError.timedOut }
    guard Self.succeeded(result.termination) else {
      throw Self.runtimeError(Self.processError(result.termination))
    }
    let models = Self.parseModels(result.standardOutput.tail)
    guard !models.isEmpty else {
      throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
    }
    if let selectedModelID, !models.contains(where: { $0.id == selectedModelID }) {
      throw AgentRuntimeError.modelUnavailable(selectedModelID)
    }
    return models
  }

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
        prompt: request.prompt,
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

  private func validate(
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
    guard !request.networkAccessRequested else {
      throw AgentRuntimeError.invalidRequest("request.networkAccessRequested")
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

  private func makeRunDirectory() throws -> String {
    let base = try Self.preparePrivateDirectory(configuration.runtimeBaseDirectory)
    let path = URL(fileURLWithPath: base, isDirectory: true)
      .appendingPathComponent("run-\(UUID().uuidString.lowercased())", isDirectory: true).path
    return try Self.preparePrivateDirectory(path)
  }

  private static let advertisedCapabilities: Set<AgentCapability> = [
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
  ]

  private static let enforcedCapabilities: Set<AgentCapability> = [
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
  ]

  private static let runtimeCapabilities = capabilities(
    observed: [
      .sessionCreate,
      .sessionContinue,
      .steer,
      .workspaceRead,
      .workspaceWriteInPlace,
      .modelSelection,
      .effortSelection,
    ]
  )

  private static func capabilities(
    observed: Set<AgentCapability>
  ) -> AgentCapabilitySnapshot {
    AgentCapabilitySnapshot(
      advertised: advertisedCapabilities,
      observed: observed,
      enforced: enforcedCapabilities
    )
  }

  private static func parseModels(_ output: String) -> [AgentModelDescriptor] {
    let plain = output.replacingOccurrences(
      of: "\u{001B}\\[[0-9;]*m",
      with: "",
      options: .regularExpression
    )
    var seen = Set<String>()
    return plain.split(separator: "\n").compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { return nil }
      let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      guard let slugPart = fields.first else { return nil }
      let slug = String(slugPart)
      guard seen.insert(slug).inserted,
        slug.utf8.count <= 256,
        slug.rangeOfCharacter(from: .controlCharacters) == nil,
        !slug.contains(":")
      else { return nil }
      let displayName =
        fields.count == 2
        ? String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        : slug
      let efforts = Self.efforts(slug: slug, displayName: displayName)
      return try? AgentModelDescriptor(
        id: slug,
        displayName: displayName.isEmpty ? slug : displayName,
        supportedReasoningEfforts: efforts,
        defaultReasoningEffort: efforts.count == 1 ? efforts[0] : nil
      )
    }
  }

  private static func efforts(slug: String, displayName: String) -> [String] {
    let values = ["low", "medium", "high"]
    let lowerSlug = slug.lowercased()
    if let effort = values.first(where: { lowerSlug.hasSuffix("-\($0)") }) {
      return [effort]
    }
    let lowerDisplayName = displayName.lowercased()
    if let effort = values.first(where: {
      lowerDisplayName.contains("(\($0))") || lowerDisplayName.hasSuffix(" \($0)")
    }) {
      return [effort]
    }
    return values
  }

  private static func succeeded(_ termination: ManagedProcessTermination) -> Bool {
    if case .exited(0) = termination { return true }
    return false
  }

  private static func processError(_ termination: ManagedProcessTermination) -> AntigravityCLIError
  {
    switch termination {
    case .exited(let code): .processExited(code)
    case .killed: .processExited(nil)
    case .notStarted: .processExited(nil)
    }
  }

  private static func probeReason(_ error: any Error) -> String {
    switch error {
    case AntigravityCLIError.unsupportedVersion(let version):
      "Antigravity CLI version is incompatible: \(version)."
    case AntigravityCLIError.requestTimedOut:
      "Antigravity CLI capability Probe timed out."
    case AgentRuntimeError.unsupportedProtocol(let protocolID):
      "Antigravity CLI does not support the required protocol surface: \(protocolID)."
    case AgentRuntimeError.installationUnavailable:
      "The Antigravity CLI executable is unavailable or unsafe."
    case AntigravityCLIError.processExited(let code):
      "Antigravity CLI capability Probe exited with code \(code.map(String.init) ?? "unknown")."
    default:
      "Antigravity CLI capability Probe failed."
    }
  }

  private static func requiresReview(_ error: any Error) -> Bool {
    if case AntigravityCLIError.unsupportedVersion = error { return true }
    return false
  }

  private static func runtimeError(_ error: any Error) -> AgentRuntimeError {
    if let error = error as? AgentRuntimeError { return error }
    guard let error = error as? AntigravityCLIError else { return .processUnavailable }
    return switch error {
    case .invalidMessage:
      .malformedEvent("antigravity-stream-json")
    case .oversizedFrame:
      .oversizedFrame
    case .transportClosed:
      .processUnavailable
    case .processExited(let code):
      .processExited(code)
    case .requestTimedOut:
      .timedOut
    case .sessionMismatch:
      .sessionMismatch
    case .modelMismatch(let model):
      .modelUnavailable(model)
    case .unsupportedVersion(let version):
      .unsupportedProtocol("antigravity-\(version)")
    case .permissionDenied:
      .approvalUnavailable("antigravity-headless")
    }
  }

  private static func resolvedExecutable(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
    }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    var metadata = stat()
    guard stat(resolved, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      access(resolved, X_OK) == 0,
      metadata.st_uid == getuid() || metadata.st_uid == 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0
    else {
      throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
    }
    return resolved
  }

  private static func preparePrivateDirectory(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest("runtimeBaseDirectory")
    }
    let requested = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: requested,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(requested, 0o700) == 0 else { throw AgentRuntimeError.processUnavailable }
      var metadata = stat()
      guard lstat(requested, &metadata) == 0,
        metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_mode & 0o777 == 0o700
      else {
        throw AgentRuntimeError.processUnavailable
      }
      return URL(fileURLWithPath: requested, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }
}
