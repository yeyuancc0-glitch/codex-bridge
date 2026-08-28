import BridgeCodexRPC
import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import Foundation

package actor ExecutionSession {
  struct PendingApproval: Sendable {
    let rpcRequestID: RequestID
    let response: ExecutionApprovalResponse
    let request: ExecutionApprovalRequest
  }

  struct ApprovalRequestKey: Hashable, Sendable {
    let method: String
    let threadID: String
    let turnID: String
    let itemID: String
    let callbackID: String?
  }

  nonisolated let events: AsyncStream<ExecutionEvent>

  let taskID: TaskID
  let client: CodexAppServerClient
  let configuration: ExecutionManagerConfiguration
  let projectRoot: String
  let approvalLimits: ExecutionApprovalLimits
  let onTermination: @Sendable (TaskID, ExecutionSession) async -> Void
  let continuation: AsyncStream<ExecutionEvent>.Continuation

  var eventTask: Task<Void, Never>?
  var lifetimeTask: Task<Void, Never>?
  var expectedThreadID: String?
  var binding: ExecutionBinding?
  var startedTurnIDs: Set<String> = []
  var collaborationBindings: Set<ExecutionBinding> = []
  var seenItems: [CodexApprovalItemKey: String] = [:]
  var knownItems: [CodexApprovalItemKey: CodexApprovalItemEvidence] = [:]
  var usedApprovalRequests: Set<ApprovalRequestKey> = []
  var pendingApprovals: [String: PendingApproval] = [:]
  var approvalBarriers: Set<String> = []
  var deferredRequests: [RPCServerRequest] = []
  var deferredCompletion: TurnNotification?
  var seenSemanticSources: Set<String> = []
  var terminal = false

  init(
    taskID: TaskID,
    configuration: ExecutionManagerConfiguration,
    projectRoot: String,
    approvalLimits: ExecutionApprovalLimits,
    onTermination: @escaping @Sendable (TaskID, ExecutionSession) async -> Void
  ) {
    let pair = AsyncStream.makeStream(
      of: ExecutionEvent.self,
      bufferingPolicy: .bufferingOldest(configuration.outputBufferLimit)
    )
    self.taskID = taskID
    self.configuration = configuration
    self.projectRoot = projectRoot
    self.approvalLimits = approvalLimits
    self.onTermination = onTermination
    client = CodexAppServerClient(
      configuration: configuration.appServer,
      defaultTimeoutNanoseconds: configuration.requestTimeoutNanoseconds,
      eventBufferLimit: configuration.eventBufferLimit
    )
    events = pair.stream
    continuation = pair.continuation
  }

  func start(_ request: ExecutionRequest) async throws -> ExecutionBinding {
    guard request.task.id == taskID else {
      throw ExecutionServiceError.invalidRequest("task.id")
    }
    try validateProjectPolicy(request)
    do {
      try request.project.root.validateCurrentIdentity()
    } catch {
      throw ExecutionServiceError.projectIdentityChanged(request.project.id)
    }

    beginConsumingEvents()
    do {
      try await client.start()
      _ = try await client.initialize(
        clientInfo: configuration.clientInfo,
        capabilities: InitializeCapabilities(
          experimentalAPI: configuration.synchronizeCodexProjects
        )
      )
      let fastTierID = try await validateModel(
        model: request.task.executionModel,
        effort: request.task.executionEffort,
        fastMode: request.task.fastMode
      )
      let posture = Self.posture(
        for: request,
        root: projectRoot,
        fastServiceTierID: fastTierID
      )
      let threadID = try await prepareThread(request, posture: posture)
      expectedThreadID = threadID
      let turn = try await client.startTurn(
        TurnStartParams(
          threadId: threadID,
          text: request.task.prompt,
          sandboxPolicy: posture.sandboxPolicy,
          approvalPolicy: posture.approvalPolicy,
          approvalsReviewer: posture.approvalsReviewer,
          serviceTier: posture.serviceTier,
          model: request.task.executionModel,
          effort: request.task.executionEffort
        )
      )
      guard Self.isSafeWireIdentifier(turn.turn.id) else {
        throw ExecutionServiceError.protocolViolation("turn identifier")
      }
      let binding = try ExecutionBinding(threadID: threadID, turnID: turn.turn.id)
      try await activate(binding)
      return binding
    } catch let error as ExecutionServiceError {
      await shutdown()
      throw error
    } catch is CancellationError {
      await shutdown()
      throw CancellationError()
    } catch {
      await shutdown()
      throw ExecutionServiceError.processUnavailable
    }
  }

  func matches(_ requested: ExecutionBinding) -> Bool {
    !terminal && binding == requested
  }

  func pendingApprovalRequests() -> [ExecutionApprovalRequest] {
    pendingApprovals.values.map(\.request).sorted { $0.id < $1.id }
  }

  func steer(expectedTurnID: String, text: String) async throws {
    let binding = try activeBinding(expectedTurnID: expectedTurnID)
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, prompt.utf8.count <= 64 * 1_024, !prompt.contains("\0") else {
      throw ExecutionServiceError.invalidRequest("steer.text")
    }
    do {
      let response = try await client.steerTurn(
        TurnSteerParams(
          threadId: binding.threadID,
          expectedTurnId: binding.turnID,
          text: prompt
        )
      )
      guard response.turnId == binding.turnID else {
        throw ExecutionServiceError.bindingMismatch
      }
    } catch let error as ExecutionServiceError {
      throw error
    } catch {
      throw ExecutionServiceError.processUnavailable
    }
  }

  func interrupt(expectedTurnID: String?) async throws {
    let binding = try activeBinding(expectedTurnID: expectedTurnID)
    do {
      _ = try await client.interruptTurn(
        TurnInterruptParams(threadId: binding.threadID, turnId: binding.turnID)
      )
    } catch {
      throw ExecutionServiceError.processUnavailable
    }
  }

  func respondToApproval(id: String, decision: LocalApprovalDecision) async throws {
    guard !terminal, let pending = pendingApprovals[id] else {
      throw ExecutionServiceError.approvalUnavailable(id)
    }
    guard isKnownBinding(pending.request.binding) else {
      await fail(code: "approval_binding_mismatch", summary: "Codex approval binding mismatch.")
      throw ExecutionServiceError.bindingMismatch
    }
    let result = try pending.response.value(for: decision)
    pendingApprovals.removeValue(forKey: id)
    approvalBarriers.insert(id)
    do {
      try await client.respond(
        to: pending.rpcRequestID,
        result: result
      )
    } catch {
      approvalBarriers.remove(id)
      await fail(code: "approval_response_failed", summary: "The Codex approval response failed.")
      throw ExecutionServiceError.processUnavailable
    }
  }

  func finalizeApproval(id: String, committed: Bool) async {
    guard !terminal, approvalBarriers.remove(id) != nil else { return }
    guard committed else {
      await fail(
        code: "approval_state_not_committed",
        summary: "The local approval state was not committed."
      )
      return
    }
    guard approvalBarriers.isEmpty, pendingApprovals.isEmpty, let completion = deferredCompletion
    else { return }
    deferredCompletion = nil
    await processTurnCompletion(completion)
  }

  func shutdown() async {
    guard !terminal else {
      await client.stop()
      return
    }
    terminal = true
    eventTask?.cancel()
    lifetimeTask?.cancel()
    continuation.finish()
    await client.stop()
  }

  private func beginConsumingEvents() {
    guard eventTask == nil else { return }
    let source = client.events
    eventTask = Task { [weak self] in
      for await event in source {
        guard let self else { return }
        await self.receive(event)
      }
      await self?.eventStreamEnded()
    }
    let lifetime = configuration.maximumSessionNanoseconds
    lifetimeTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: lifetime)
      } catch {
        return
      }
      await self?.fail(
        code: "execution_timeout",
        summary: "The Codex execution session exceeded its allowed duration."
      )
    }
  }

  private func activate(_ requested: ExecutionBinding) async throws {
    let startedAt = ContinuousClock.now
    let timeout = Duration.nanoseconds(
      Int64(min(configuration.turnStartTimeoutNanoseconds, UInt64(Int64.max)))
    )
    while !startedTurnIDs.contains(requested.turnID) {
      guard !terminal else { throw ExecutionServiceError.sessionEnded(taskID) }
      guard ContinuousClock.now - startedAt < timeout else {
        throw ExecutionServiceError.turnStartTimedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    guard requested.threadID == expectedThreadID else {
      throw ExecutionServiceError.bindingMismatch
    }
    binding = requested

    let requests = deferredRequests
    deferredRequests.removeAll(keepingCapacity: false)
    for request in requests {
      await processServerRequest(request)
      guard !terminal else { throw ExecutionServiceError.sessionEnded(taskID) }
    }
    if let completion = deferredCompletion, pendingApprovals.isEmpty {
      deferredCompletion = nil
      await processTurnCompletion(completion)
    }
  }

}
