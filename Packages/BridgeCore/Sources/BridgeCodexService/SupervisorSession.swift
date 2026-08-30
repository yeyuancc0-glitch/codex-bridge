import BridgeCodexRPC
import BridgeDomain
import BridgeSupervisor
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

package actor SupervisorSession {
  nonisolated let events: AsyncStream<SupervisorEvent>

  let taskID: TaskID
  let model: String
  let effort: String
  let goal: String
  let configuration: SupervisorManagerConfiguration
  let client: CodexAppServerClient
  let continuation: AsyncStream<SupervisorEvent>.Continuation
  let onTermination: @Sendable (TaskID, SupervisorSession) async -> Void

  var scratchURL: URL?
  var threadID: String?
  var eventTask: Task<Void, Never>?
  var bootstrapTask: Task<Void, Never>?
  var drainTask: Task<Void, Never>?
  var completions: [String: TurnNotification] = [:]
  var pending: [SupervisorObservation] = []
  var failure: SupervisorServiceError?
  // Sticky because a rejected approval request can race with final verdict handling.
  var approvalRequested = false
  var seenIssueIDs: Set<String> = []
  var automaticSteerCount = 0
  var terminal = false
  var ready = false

  init(
    taskID: TaskID,
    model: String,
    effort: String,
    goal: String,
    configuration: SupervisorManagerConfiguration,
    onTermination: @escaping @Sendable (TaskID, SupervisorSession) async -> Void
  ) {
    let pair = AsyncStream.makeStream(
      of: SupervisorEvent.self,
      bufferingPolicy: .bufferingOldest(configuration.outputBufferLimit)
    )
    self.taskID = taskID
    self.model = model
    self.effort = effort
    self.goal = goal
    self.configuration = configuration
    self.onTermination = onTermination
    client = CodexAppServerClient(
      configuration: configuration.appServer,
      defaultTimeoutNanoseconds: configuration.requestTimeoutNanoseconds,
      eventBufferLimit: configuration.eventBufferLimit
    )
    events = pair.stream
    continuation = pair.continuation
  }

  func launch() {
    guard bootstrapTask == nil, !terminal else { return }
    bootstrapTask = Task { [weak self] in
      await self?.bootstrap()
    }
  }

  func observe(_ observation: SupervisorObservation) {
    guard !terminal, observation.taskID == taskID else { return }
    if pending.count >= configuration.maximumQueuedObservations {
      if let index = pending.firstIndex(where: { $0.kind == .progress }) {
        pending.remove(at: index)
      } else {
        degrade(
          code: "supervisor_queue_capacity",
          summary: "Supervisor observation capacity was exceeded."
        )
        return
      }
    }
    if observation.kind == .final {
      pending.removeAll(where: { $0.kind == .progress })
    }
    pending.append(observation)
    beginDrainIfReady()
  }

  func shutdown() async {
    guard !terminal else {
      await client.stop()
      removeScratch()
      return
    }
    terminal = true
    bootstrapTask?.cancel()
    drainTask?.cancel()
    eventTask?.cancel()
    continuation.finish()
    await client.stop()
    removeScratch()
  }

  private func bootstrap() async {
    do {
      let scratch = try Self.makeScratch(in: configuration.scratchRootURL)
      scratchURL = scratch
      beginConsumingEvents()
      try await client.start()
      _ = try await client.initialize(clientInfo: configuration.clientInfo)
      try await validateModel()
      let response = try await client.startThread(
        ThreadStartParams(
          cwd: scratch.path,
          sandbox: .readOnly,
          approvalPolicy: .never,
          ephemeral: false,
          model: model,
          developerInstructions: Self.developerInstructions
        )
      )
      guard response.thread.cwd == scratch.path,
        response.cwd == scratch.path,
        response.thread.ephemeral == false,
        response.model == model,
        response.approvalPolicy == .never,
        response.sandbox == .readOnly(networkAccess: false),
        ExecutionSession.isSafeWireIdentifier(response.thread.id)
      else {
        throw SupervisorServiceError.threadUnavailable
      }
      threadID = response.thread.id
      ready = true
      yield(.started)
      beginDrainIfReady()
    } catch is CancellationError {
      if !terminal {
        degrade(code: "supervisor_cancelled", summary: "Supervisor startup was cancelled.")
      }
    } catch let error as SupervisorServiceError {
      degrade(code: Self.code(error), summary: error.localizedDescription)
    } catch {
      degrade(code: "supervisor_start_failed", summary: "Supervisor could not start.")
    }
  }

  private func validateModel() async throws {
    var cursor: String?
    for _ in 0..<8 {
      let page: ModelListResponse
      do {
        page = try await client.listModels(
          ModelListParams(cursor: cursor, limit: 100, includeHidden: false)
        )
      } catch {
        throw SupervisorServiceError.processUnavailable
      }
      if let available = page.data.first(where: { $0.id == model }) {
        guard
          available.supportedReasoningEfforts.contains(where: {
            $0.reasoningEffort == effort
          })
        else {
          throw SupervisorServiceError.effortUnavailable(effort)
        }
        return
      }
      guard let next = page.nextCursor, !next.isEmpty, next != cursor else { break }
      cursor = next
    }
    throw SupervisorServiceError.modelUnavailable(model)
  }

  private func beginDrainIfReady() {
    guard ready, !terminal, drainTask == nil, !pending.isEmpty else { return }
    drainTask = Task { [weak self] in
      await self?.drain()
    }
  }

  private func drain() async {
    defer {
      drainTask = nil
      beginDrainIfReady()
    }
    while !terminal, !pending.isEmpty {
      let observation = pending.removeFirst()
      do {
        let decision = try await review(observation)
        handle(decision, observation: observation)
      } catch is CancellationError {
        return
      } catch let error as SupervisorServiceError {
        degrade(code: Self.code(error), summary: error.localizedDescription)
        return
      } catch {
        degrade(code: "supervisor_review_failed", summary: "Supervisor review failed.")
        return
      }
    }
  }

  private func review(_ observation: SupervisorObservation) async throws -> SupervisorDecision {
    guard let threadID, ready, !terminal else {
      throw SupervisorServiceError.sessionUnavailable(taskID)
    }
    if let failure { throw failure }
    let prompt = try Self.prompt(observation)
    let response: TurnStartResponse
    do {
      response = try await client.startTurn(
        TurnStartParams(
          threadId: threadID,
          text: prompt,
          sandboxPolicy: .readOnly(networkAccess: false),
          approvalPolicy: .never,
          model: model,
          effort: effort,
          outputSchema: try Self.outputSchema()
        )
      )
    } catch {
      throw SupervisorServiceError.turnUnavailable
    }
    guard ExecutionSession.isSafeWireIdentifier(response.turn.id) else {
      throw SupervisorServiceError.turnUnavailable
    }
    let completed = try await waitForCompletion(turnID: response.turn.id)
    guard completed.threadId == threadID,
      completed.turn.id == response.turn.id,
      completed.turn.status == "completed"
    else {
      throw SupervisorServiceError.turnUnavailable
    }
    return try Self.decodeDecision(completed.turn, observation: observation)
  }

  private func waitForCompletion(turnID: String) async throws -> TurnNotification {
    let start = ContinuousClock.now
    let timeout = Duration.nanoseconds(
      Int64(min(configuration.reviewTimeoutNanoseconds, UInt64(Int64.max)))
    )
    while ContinuousClock.now - start < timeout {
      if let failure { throw failure }
      if let completion = completions.removeValue(forKey: turnID) {
        return completion
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw SupervisorServiceError.reviewTimedOut
  }

  private func handle(
    _ decision: SupervisorDecision,
    observation: SupervisorObservation
  ) {
    if observation.kind == .final {
      if let failure {
        degrade(code: Self.code(failure), summary: failure.localizedDescription)
        return
      }
      if approvalRequested {
        degrade(
          code: Self.code(.approvalRequested),
          summary: "Supervisor requested user approval; Codex execution continues."
        )
        return
      }
    }
    switch decision.decision {
    case .continue:
      if observation.kind == .final {
        finish(summary: decision.summary)
      } else {
        yield(.decision(decision))
      }

    case .steer:
      guard observation.kind == .progress, let instruction = decision.instruction else {
        yield(.attention(summary: decision.summary))
        if observation.kind == .final { finish(summary: decision.summary) }
        return
      }
      let issueID = decision.issueID ?? "steer-\(automaticSteerCount)"
      guard automaticSteerCount < configuration.maximumAutomaticSteers,
        seenIssueIDs.insert(issueID).inserted
      else {
        yield(.attention(summary: decision.summary))
        return
      }
      automaticSteerCount += 1
      yield(.steer(instruction: instruction, summary: decision.summary))

    case .finalAccept:
      guard observation.kind == .final else {
        yield(.attention(summary: "Supervisor attempted a premature final acceptance."))
        return
      }
      finish(summary: decision.summary)

    case .suspend, .interrupt, .finalReject:
      yield(.attention(summary: decision.summary))
      if observation.kind == .final { finish(summary: decision.summary) }
    }
  }

  private func beginConsumingEvents() {
    guard eventTask == nil else { return }
    let source = client.events
    eventTask = Task { [weak self] in
      for await event in source {
        guard let self else { return }
        await self.receive(event)
      }
      await self?.streamEnded()
    }
  }

  private func yield(_ event: SupervisorEvent) {
    switch continuation.yield(event) {
    case .enqueued:
      return
    case .dropped, .terminated:
      degrade(
        code: "supervisor_event_capacity",
        summary: "Supervisor event capacity was exceeded."
      )
    @unknown default:
      degrade(
        code: "supervisor_event_capacity",
        summary: "Supervisor event capacity was exceeded."
      )
    }
  }

  private func finish(summary: String) {
    guard !terminal else { return }
    terminal = true
    _ = continuation.yield(.completed(summary: summary))
    continuation.finish()
    bootstrapTask?.cancel()
    drainTask?.cancel()
    eventTask?.cancel()
    Task { [weak self, client, onTermination, taskID] in
      await client.stop()
      guard let self else { return }
      await self.cleanupAfterStop()
      await onTermination(taskID, self)
    }
  }

  private func degrade(code: String, summary: String) {
    guard !terminal else { return }
    terminal = true
    _ = continuation.yield(.degraded(code: code, summary: summary))
    continuation.finish()
    bootstrapTask?.cancel()
    drainTask?.cancel()
    eventTask?.cancel()
    Task { [weak self, client, onTermination, taskID] in
      await client.stop()
      guard let self else { return }
      await self.cleanupAfterStop()
      await onTermination(taskID, self)
    }
  }

  private func cleanupAfterStop() {
    removeScratch()
  }

  private func removeScratch() {
    guard let scratchURL else { return }
    Self.removeScratch(scratchURL, root: configuration.scratchRootURL)
    self.scratchURL = nil
  }

  private static func makeScratch(in root: URL) throws -> URL {
    guard privateDirectory(root) else { throw SupervisorServiceError.scratchUnavailable }
    let child = root.appending(
      path: "session-" + UUID().uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    do {
      try FileManager.default.createDirectory(
        at: child,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
    } catch {
      throw SupervisorServiceError.scratchUnavailable
    }
    guard privateDirectory(child) else {
      try? FileManager.default.removeItem(at: child)
      throw SupervisorServiceError.scratchUnavailable
    }
    return child
  }

  private static func removeScratch(_ child: URL, root: URL) {
    let rootPath = root.standardizedFileURL.path
    let childPath = child.standardizedFileURL.path
    guard childPath.hasPrefix(rootPath + "/"),
      child.lastPathComponent.hasPrefix("session-"),
      privateDirectory(root),
      privateDirectory(child)
    else { return }
    try? FileManager.default.removeItem(at: child)
  }

  private static func privateDirectory(_ url: URL) -> Bool {
    #if os(Windows)
      // Windows uses ACLs; owner check applies to POSIX.
      let attributes = url.path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
      return attributes != INVALID_FILE_ATTRIBUTES
        && attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
    #else
      var metadata = stat()
      return lstat(url.path, &metadata) == 0
        && metadata.st_uid == getuid()
        && metadata.st_mode & S_IFMT == S_IFDIR
        && metadata.st_mode & 0o777 == 0o700
    #endif
  }

  private static func code(_ error: SupervisorServiceError) -> String {
    switch error {
    case .invalidRequest: "supervisor_invalid_request"
    case .activeSession: "supervisor_active_session"
    case .sessionLimitReached: "supervisor_session_limit"
    case .sessionUnavailable: "supervisor_session_unavailable"
    case .scratchUnavailable: "supervisor_scratch_unavailable"
    case .modelUnavailable: "supervisor_model_unavailable"
    case .effortUnavailable: "supervisor_effort_unavailable"
    case .threadUnavailable: "supervisor_thread_unavailable"
    case .turnUnavailable: "supervisor_turn_unavailable"
    case .reviewTimedOut: "supervisor_review_timeout"
    case .approvalRequested: "supervisor_approval_requested"
    case .invalidDecision: "supervisor_invalid_decision"
    case .processUnavailable: "supervisor_process_unavailable"
    }
  }

  private static let developerInstructions = """
    You are the Codex Bridge Supervisor. Review only the structured task summaries supplied by \
    Codex Bridge. You are read-only, cannot approve operations, cannot modify project files, and \
    must not invent evidence. Prefer continue unless a concrete deviation warrants a bounded steer. \
    Suspend, interrupt, or final rejection decisions are advisory and require local user attention.
    """
}
