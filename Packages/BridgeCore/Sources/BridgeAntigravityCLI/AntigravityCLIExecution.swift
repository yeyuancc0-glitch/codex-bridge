import BridgeAgentCore
import BridgeDomain
import Foundation

public actor AntigravityCLIExecution {
  public nonisolated let events: AsyncThrowingStream<AgentEventEnvelope, any Error>
  public nonisolated let bindings: AsyncThrowingStream<AgentBinding, any Error>

  private let taskID: TaskID
  private let installationID: AgentInstallationID
  private let projectRoot: String
  private let requestedSessionID: String?
  private let expectedModel: String?
  private let initialPrompt: String
  private let runID: String
  private let transport: any AntigravityCLITransport
  private let inactivityTimeout: Duration
  private let cleanup: @Sendable () -> Void
  private let beforeResultNormalization: @Sendable () async -> Void
  private let eventContinuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
  private let bindingContinuation: AsyncThrowingStream<AgentBinding, any Error>.Continuation
  private var eventTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var normalizer: AntigravityCLIEventNormalizer?
  private var binding: AgentBinding?
  private var queuedSteers: [String] = []
  private var queuedSteerBytes = 0
  private var promptInFlight = false
  private var turnFinalizing = false
  private var interruptRequested = false
  private var permissionDenied = false
  private var permissionDeniedToolName: String?
  private var lastFailedTool: (name: String, stepIndex: Int)?
  private var permissionMode: String?
  private var nativeToolCapabilities: Set<AgentCapability> = []
  private var terminal = false
  private var initialized = false

  private static let maximumQueuedSteers = 32
  private static let maximumQueuedSteerBytes = 256 * 1_024

  public init(
    taskID: TaskID,
    installationID: AgentInstallationID,
    projectRoot: String,
    requestedSessionID: String?,
    expectedModel: String? = nil,
    prompt: String,
    runID: String = UUID().uuidString.lowercased(),
    transport: any AntigravityCLITransport,
    inactivityTimeout: Duration = .seconds(10 * 60),
    eventBufferLimit: Int = 256,
    cleanup: @escaping @Sendable () -> Void
  ) {
    self.init(
      taskID: taskID,
      installationID: installationID,
      projectRoot: projectRoot,
      requestedSessionID: requestedSessionID,
      expectedModel: expectedModel,
      prompt: prompt,
      runID: runID,
      transport: transport,
      inactivityTimeout: inactivityTimeout,
      eventBufferLimit: eventBufferLimit,
      cleanup: cleanup,
      beforeResultNormalization: {}
    )
  }

  init(
    taskID: TaskID,
    installationID: AgentInstallationID,
    projectRoot: String,
    requestedSessionID: String?,
    expectedModel: String? = nil,
    prompt: String,
    runID: String = UUID().uuidString.lowercased(),
    transport: any AntigravityCLITransport,
    inactivityTimeout: Duration = .seconds(10 * 60),
    eventBufferLimit: Int = 256,
    cleanup: @escaping @Sendable () -> Void,
    beforeResultNormalization: @escaping @Sendable () async -> Void
  ) {
    let eventPair = AsyncThrowingStream.makeStream(
      of: AgentEventEnvelope.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(max(1, eventBufferLimit))
    )
    let bindingPair = AsyncThrowingStream.makeStream(
      of: AgentBinding.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingNewest(1)
    )
    self.taskID = taskID
    self.installationID = installationID
    self.projectRoot = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
    self.requestedSessionID = requestedSessionID
    self.expectedModel = expectedModel
    initialPrompt = prompt
    self.runID = runID
    self.transport = transport
    self.inactivityTimeout = inactivityTimeout
    self.cleanup = cleanup
    self.beforeResultNormalization = beforeResultNormalization
    events = eventPair.stream
    eventContinuation = eventPair.continuation
    bindings = bindingPair.stream
    bindingContinuation = bindingPair.continuation
  }

  public func start() {
    guard eventTask == nil, !terminal else { return }
    let source = transport.incoming
    eventTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await frame in source {
          await self.consume(frame)
        }
        await self.streamEnded(failure: nil)
      } catch {
        await self.streamEnded(failure: error)
      }
    }
    armWatchdog()
  }

  public nonisolated func waitForBinding(timeout: Duration) async throws -> AgentBinding {
    try await withThrowingTaskGroup(of: AgentBinding.self) { group in
      let bindings = self.bindings
      group.addTask {
        for try await binding in bindings { return binding }
        throw AntigravityCLIError.transportClosed
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw AntigravityCLIError.requestTimedOut
      }
      guard let result = try await group.next() else {
        throw AntigravityCLIError.transportClosed
      }
      group.cancelAll()
      return result
    }
  }

  public func steer(text: String) throws {
    guard initialized, !terminal, !interruptRequested, !turnFinalizing else {
      throw AgentRuntimeError.processUnavailable
    }
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, prompt.utf8.count <= 64 * 1_024, !prompt.contains("\0") else {
      throw AgentRuntimeError.invalidRequest("steer.text")
    }
    guard queuedSteers.count < Self.maximumQueuedSteers,
      queuedSteerBytes + prompt.utf8.count <= Self.maximumQueuedSteerBytes
    else {
      throw AgentRuntimeError.invalidRequest("steer.queue")
    }
    queuedSteers.append(prompt)
    queuedSteerBytes += prompt.utf8.count
  }

  public func observedNativeToolCapabilities() -> Set<AgentCapability> {
    nativeToolCapabilities
  }

  public func interrupt() async throws {
    guard initialized, !terminal else { throw AgentRuntimeError.processUnavailable }
    interruptRequested = true
    await transport.interrupt()
  }

  public func shutdown() async {
    guard claimTerminal() else { return }
    interruptRequested = true
    await transport.interrupt()
    if let normalizer, let event = try? await normalizer.interrupted() {
      _ = emit(event)
    }
    await closeStream()
  }

  private func consume(_ frame: Data) async {
    guard !terminal else { return }
    armWatchdog()
    do {
      let envelope = try AntigravityWireCodec.decode(frame)
      switch envelope.event {
      case "init":
        try await initialize(envelope)
      case "step_update":
        guard let update = envelope.stepUpdate, let normalizer else {
          throw AntigravityCLIError.invalidMessage
        }
        let toolName = update.toolInfo?.name ?? update.toolName
        if update.stepType == "tool",
          update.state == "ERROR" || update.toolInfo?.error != nil || update.error != nil,
          let toolName
        {
          lastFailedTool = (toolName, update.stepIndex)
        }
        if AntigravityPermissionEvidence.detected(in: update.toolInfo?.error?.message)
          || AntigravityPermissionEvidence.detected(in: update.error?.message)
        {
          permissionDenied = true
          let precedingToolName = lastFailedTool.flatMap {
            $0.stepIndex + 1 == update.stepIndex ? $0.name : nil
          }
          permissionDeniedToolName = toolName ?? precedingToolName
        }
        for event in try await normalizer.normalize(update) {
          guard !terminal else { return }
          guard emit(event) else { throw AntigravityCLIError.transportClosed }
        }
      case "result":
        guard let result = envelope.result, let normalizer else {
          throw AntigravityCLIError.invalidMessage
        }
        try await consume(result, normalizer: normalizer)
      default:
        throw AntigravityCLIError.invalidMessage
      }
    } catch {
      await failExecution(
        code: "antigravity_protocol_violation",
        summary: Self.failureSummary(error),
        cause: error
      )
    }
  }

  private func initialize(_ envelope: AntigravityStreamEnvelope) async throws {
    guard !initialized,
      let sessionID = envelope.conversationID,
      let initialization = envelope.initialization,
      !sessionID.isEmpty,
      sessionID.utf8.count <= 1_024,
      initialization.tools.count <= 512,
      Self.acceptedPermissionModes.contains(initialization.permissionMode)
    else {
      throw AntigravityCLIError.invalidMessage
    }
    let cwd = URL(fileURLWithPath: initialization.cwd).standardizedFileURL.path
    guard cwd == projectRoot else { throw AntigravityCLIError.sessionMismatch }
    if let requestedSessionID, requestedSessionID != sessionID {
      throw AntigravityCLIError.sessionMismatch
    }
    if let expectedModel, initialization.model != expectedModel {
      throw AntigravityCLIError.modelMismatch(expectedModel)
    }
    let binding = try AgentBinding(
      providerID: .antigravity,
      installationID: installationID,
      providerSessionID: sessionID,
      providerRunID: runID
    )
    self.binding = binding
    permissionMode = initialization.permissionMode
    nativeToolCapabilities = Self.capabilities(for: initialization.tools)
    normalizer = AntigravityCLIEventNormalizer(
      taskID: taskID,
      binding: binding,
      projectRoot: projectRoot
    )
    initialized = true
    _ = bindingContinuation.yield(binding)
    bindingContinuation.finish()
    try await sendPrompt(initialPrompt)
  }

  private static func capabilities(for tools: [String]) -> Set<AgentCapability> {
    var result: Set<AgentCapability> = tools.isEmpty ? [] : [.toolLifecycle]
    for tool in tools.map({ $0.lowercased() }) {
      if tool.contains("command") || tool.contains("shell") || tool.contains("terminal") {
        result.insert(.shell)
      }
      if tool.contains("search_web") || tool.contains("web_search") {
        result.insert(.webSearch)
      }
      if tool.contains("url") || tool.contains("fetch") || tool.contains("browser") {
        result.insert(.webFetch)
      }
      if tool.contains("mcp") {
        result.insert(.mcpClient)
      }
      if tool.contains("subagent") || tool.contains("delegate") {
        result.insert(.subagents)
        result.insert(.childRuns)
      }
    }
    return result
  }

  private func consume(
    _ result: AntigravityResult,
    normalizer: AntigravityCLIEventNormalizer
  ) async throws {
    guard promptInFlight, !turnFinalizing else { throw AntigravityCLIError.invalidMessage }
    promptInFlight = false
    turnFinalizing = true
    let denied = await permissionWasDenied(result: result)
    guard !terminal else { return }

    if interruptRequested {
      for event in try await normalizer.normalize(
        result,
        permissionDenied: false,
        terminal: false
      ) {
        guard !terminal else { return }
        guard emit(event) else { throw AntigravityCLIError.transportClosed }
      }
      guard claimTerminal() else { return }
      guard emit(try await normalizer.interrupted()) else {
        throw AntigravityCLIError.transportClosed
      }
      await closeStream()
      return
    }

    let status = result.status.uppercased()
    let canContinue = status == "SUCCESS" && !denied
    let hasQueuedSteer = canContinue && !queuedSteers.isEmpty
    let terminalResult = !hasQueuedSteer
    await beforeResultNormalization()
    for event in try await normalizer.normalize(
      result,
      permissionDenied: denied,
      terminal: terminalResult,
      permissionMode: permissionMode,
      deniedToolName: permissionDeniedToolName
    ) {
      guard !terminal else { return }
      if interruptRequested, Self.isTerminalEvent(event.event) { continue }
      guard emit(event) else { throw AntigravityCLIError.transportClosed }
    }
    if interruptRequested {
      guard claimTerminal() else { return }
      guard emit(try await normalizer.interrupted()) else {
        throw AntigravityCLIError.transportClosed
      }
      await closeStream()
      return
    }
    if canContinue, let nextPrompt = dequeueSteer() {
      guard !terminal, !interruptRequested else { return }
      try await sendPrompt(nextPrompt)
      return
    }
    guard claimTerminal() else { return }
    await closeStream()
  }

  private func sendPrompt(_ prompt: String) async throws {
    guard initialized, !terminal, !interruptRequested, !promptInFlight else {
      throw AntigravityCLIError.invalidMessage
    }
    let frame = try AntigravityWireCodec.encodeUserMessage(prompt)
    permissionDenied = false
    permissionDeniedToolName = nil
    lastFailedTool = nil
    try await transport.send(frame)
    guard !terminal else { return }
    turnFinalizing = false
    promptInFlight = true
  }

  private func dequeueSteer() -> String? {
    guard !queuedSteers.isEmpty else { return nil }
    let prompt = queuedSteers.removeFirst()
    queuedSteerBytes -= prompt.utf8.count
    return prompt
  }

  private func permissionWasDenied(result: AntigravityResult) async -> Bool {
    if permissionDenied || AntigravityPermissionEvidence.detected(in: result.error) {
      return true
    }
    var output = await transport.standardErrorSnapshot()
    if AntigravityPermissionEvidence.detected(in: output) { return true }
    try? await Task.sleep(for: .milliseconds(25))
    output = await transport.standardErrorSnapshot()
    return AntigravityPermissionEvidence.detected(in: output)
  }

  private func streamEnded(failure: (any Error)?) async {
    guard !terminal else { return }
    if interruptRequested, let normalizer {
      guard claimTerminal() else { return }
      if let event = try? await normalizer.interrupted() { _ = emit(event) }
      await closeStream()
      return
    }
    let summary =
      failure.map(Self.failureSummary)
      ?? "Antigravity ended its event stream before reporting a terminal result."
    await failExecution(
      code: "antigravity_transport_closed",
      summary: summary,
      cause: failure ?? AntigravityCLIError.transportClosed
    )
  }

  private func emit(_ event: AgentEventEnvelope) -> Bool {
    switch eventContinuation.yield(event) {
    case .enqueued: true
    case .dropped, .terminated: false
    @unknown default: false
    }
  }

  private func failExecution(
    code: String,
    summary: String,
    cause: (any Error)? = nil
  ) async {
    guard claimTerminal() else { return }
    let streamError = cause ?? AntigravityCLIError.transportClosed
    bindingContinuation.finish(throwing: streamError)
    if let normalizer, let event = try? await normalizer.failed(code: code, summary: summary) {
      _ = emit(event)
      await closeStream()
    } else {
      await closeStream(throwing: streamError)
    }
  }

  private func claimTerminal() -> Bool {
    guard !terminal else { return false }
    terminal = true
    queuedSteers.removeAll(keepingCapacity: false)
    queuedSteerBytes = 0
    return true
  }

  private static func isTerminalEvent(_ event: AgentEvent) -> Bool {
    switch event {
    case .approvalAutomaticallyDenied, .completed, .interrupted, .failed:
      true
    default:
      false
    }
  }

  private func armWatchdog() {
    watchdogTask?.cancel()
    let timeout = inactivityTimeout
    watchdogTask = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      await self?.inactivityTimedOut()
    }
  }

  private func inactivityTimedOut() async {
    await transport.interrupt()
    await failExecution(
      code: "antigravity_inactivity_timeout",
      summary: "Antigravity produced no task activity before the local timeout.",
      cause: AntigravityCLIError.requestTimedOut
    )
  }

  private func closeStream(throwing error: (any Error)? = nil) async {
    watchdogTask?.cancel()
    bindingContinuation.finish()
    if let error {
      eventContinuation.finish(throwing: error)
    } else {
      eventContinuation.finish()
    }
    await transport.close()
    cleanup()
  }

  private static func failureSummary(_ error: any Error) -> String {
    switch error {
    case AntigravityCLIError.requestTimedOut:
      "Antigravity initialization timed out."
    case AntigravityCLIError.processExited:
      "Antigravity exited before reporting a terminal result."
    case AntigravityCLIError.oversizedFrame:
      "Antigravity exceeded a protocol size limit."
    case AntigravityCLIError.sessionMismatch:
      "Antigravity reported an unexpected project or conversation."
    case AntigravityCLIError.modelMismatch:
      "Antigravity reported an unexpected model selection."
    case AntigravityCLIError.permissionDenied:
      "Antigravity could not obtain a required permission."
    default:
      "Antigravity returned malformed stream-json output."
    }
  }

  private static let acceptedPermissionModes: Set<String> = [
    "always-proceed",
    "request-review",
    "proceed-in-sandbox",
    "strict",
  ]
}
