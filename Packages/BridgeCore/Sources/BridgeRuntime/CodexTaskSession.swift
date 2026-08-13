import BridgeCodexRPC
import BridgeCoordinator
import BridgeDomain
import Foundation

actor CodexTaskSession {
  private enum ApprovalKind: Sendable {
    case command
    case fileChange
    case permissions(JSONValue)

    func response(approved: Bool) -> JSONValue {
      switch self {
      case .command, .fileChange:
        return .object(["decision": .string(approved ? "accept" : "decline")])
      case .permissions(let requested):
        return .object([
          "permissions": approved ? requested : .object([:]),
          "scope": .string("turn"),
          "strictAutoReview": .bool(false),
        ])
      }
    }
  }

  private struct ItemCorrelation: Hashable, Sendable {
    let threadID: String
    let turnID: String
    let itemID: String
  }

  private struct RequestCorrelation: Hashable, Sendable {
    let method: String
    let item: ItemCorrelation
    let callbackID: String?
  }

  private struct PendingApproval: Sendable {
    let requestID: RequestID
    let correlation: RequestCorrelation
    let kind: ApprovalKind
  }

  nonisolated let observations: AsyncStream<TaskExecutionObservation>
  let client: CodexAppServerClient

  private let taskID: TaskID
  private let observationContinuation: AsyncStream<TaskExecutionObservation>.Continuation
  private let maximumPendingApprovals: Int
  private let maximumKnownItems: Int
  private let maximumSessionNanoseconds: UInt64
  private let onTermination: @Sendable (TaskID, CodexTaskSession) async -> Void
  private var eventTask: Task<Void, Never>?
  private var lifetimeTask: Task<Void, Never>?
  private var expectedThreadID: String?
  private var binding: ExecutionBinding?
  private var startedTurnIDs: Set<String> = []
  private var knownItems: [ItemCorrelation: String] = [:]
  private var usedRequests: Set<RequestCorrelation> = []
  private var pendingApprovals: [ApprovalID: PendingApproval] = [:]
  private var approvalBarriers: Set<ApprovalID> = []
  private var deferredRequests: [RPCServerRequest] = []
  private var deferredTerminalNotifications: [TurnNotification] = []
  private var terminal = false

  init(
    taskID: TaskID,
    client: CodexAppServerClient,
    observationBufferLimit: Int,
    maximumPendingApprovals: Int,
    maximumKnownItems: Int,
    maximumSessionNanoseconds: UInt64,
    onTermination: @escaping @Sendable (TaskID, CodexTaskSession) async -> Void
  ) {
    let pair = AsyncStream.makeStream(
      of: TaskExecutionObservation.self,
      bufferingPolicy: .bufferingOldest(observationBufferLimit)
    )
    self.taskID = taskID
    self.client = client
    observations = pair.stream
    observationContinuation = pair.continuation
    self.maximumPendingApprovals = maximumPendingApprovals
    self.maximumKnownItems = maximumKnownItems
    self.maximumSessionNanoseconds = maximumSessionNanoseconds
    self.onTermination = onTermination
  }

  func beginConsumingEvents() {
    guard eventTask == nil else { return }
    let events = client.events
    eventTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.receive(event)
      }
      guard let self else { return }
      await self.eventStreamEnded()
    }
    let lifetime = maximumSessionNanoseconds
    lifetimeTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: lifetime)
      } catch {
        return
      }
      await self?.fail(reason: "Execution session exceeded its allowed duration.")
    }
  }

  func hasTerminated() -> Bool {
    terminal
  }

  func startAndInitialize(clientInfo: CodexClientInfo) async throws {
    do {
      try await client.start()
      _ = try await client.initialize(clientInfo: clientInfo)
    } catch {
      throw IsolatedCodexTaskRuntimeError.initializationUnavailable
    }
  }

  func expectThread(_ threadID: String) {
    expectedThreadID = threadID
  }

  func activate(binding: ExecutionBinding, timeoutNanoseconds: UInt64) async throws {
    guard expectedThreadID == binding.threadID.rawValue else {
      throw IsolatedCodexTaskRuntimeError.bindingMismatch
    }
    let startedAt = ContinuousClock.now
    let timeout = Duration.nanoseconds(Int64(min(timeoutNanoseconds, UInt64(Int64.max))))
    while !startedTurnIDs.contains(binding.turnID.rawValue) {
      guard !terminal else { throw IsolatedCodexTaskRuntimeError.sessionEnded }
      guard ContinuousClock.now - startedAt < timeout else {
        throw IsolatedCodexTaskRuntimeError.turnStartTimedOut
      }
      do {
        try await Task.sleep(nanoseconds: 10_000_000)
      } catch {
        throw IsolatedCodexTaskRuntimeError.sessionEnded
      }
    }
    self.binding = binding
    let requests = deferredRequests
    deferredRequests.removeAll(keepingCapacity: false)
    for request in requests {
      await processServerRequest(request)
      guard !terminal else { throw IsolatedCodexTaskRuntimeError.sessionEnded }
    }
    let completions = deferredTerminalNotifications
    deferredTerminalNotifications.removeAll(keepingCapacity: false)
    for completion in completions {
      await processTurnCompletion(completion)
      guard !terminal else { throw IsolatedCodexTaskRuntimeError.sessionEnded }
    }
  }

  func resolveApproval(_ approvalID: ApprovalID, approved: Bool) async throws {
    guard !terminal, let pending = pendingApprovals.removeValue(forKey: approvalID) else {
      throw IsolatedCodexTaskRuntimeError.approvalUnavailable
    }
    guard let binding,
      pending.correlation.item.threadID == binding.threadID.rawValue,
      pending.correlation.item.turnID == binding.turnID.rawValue
    else {
      await fail(reason: "Codex approval correlation was invalid.")
      throw IsolatedCodexTaskRuntimeError.bindingMismatch
    }
    approvalBarriers.insert(approvalID)
    do {
      try await client.respond(
        to: pending.requestID, result: pending.kind.response(approved: approved))
    } catch {
      approvalBarriers.remove(approvalID)
      await fail(reason: "Codex approval response failed.")
      throw IsolatedCodexTaskRuntimeError.runtimeUnavailable
    }
  }

  func finalizeApprovalResolution(_ approvalID: ApprovalID, committed: Bool) async {
    guard !terminal, approvalBarriers.remove(approvalID) != nil else { return }
    guard committed else {
      await fail(reason: "Codex approval persistence was not confirmed.")
      return
    }
    guard approvalBarriers.isEmpty,
      let completion = deferredTerminalNotifications.first
    else {
      return
    }
    deferredTerminalNotifications.removeAll(keepingCapacity: false)
    await processTurnCompletion(completion)
  }

  func steer(binding: ExecutionBinding, prompt: String) async throws {
    try requireActive(binding)
    let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.utf8.count <= 64 * 1_024, !normalized.contains("\0")
    else {
      throw IsolatedCodexTaskRuntimeError.protocolViolation
    }
    do {
      let response = try await client.steerTurn(
        TurnSteerParams(
          threadId: binding.threadID.rawValue,
          expectedTurnId: binding.turnID.rawValue,
          text: normalized
        )
      )
      guard response.turnId == binding.turnID.rawValue else {
        await fail(reason: "Codex steer response did not match the active turn.")
        throw IsolatedCodexTaskRuntimeError.bindingMismatch
      }
    } catch let error as IsolatedCodexTaskRuntimeError {
      throw error
    } catch {
      throw IsolatedCodexTaskRuntimeError.runtimeUnavailable
    }
  }

  func interrupt(binding: ExecutionBinding) async throws {
    try requireActive(binding)
    do {
      _ = try await client.interruptTurn(
        TurnInterruptParams(
          threadId: binding.threadID.rawValue,
          turnId: binding.turnID.rawValue
        )
      )
    } catch {
      throw IsolatedCodexTaskRuntimeError.runtimeUnavailable
    }
  }

  func shutdown() async {
    guard !terminal else {
      await client.stop()
      return
    }
    terminal = true
    eventTask?.cancel()
    lifetimeTask?.cancel()
    observationContinuation.finish()
    await client.stop()
  }

  private func receive(_ event: AppServerEvent) async {
    guard !terminal else { return }
    switch event {
    case .notification(let notification):
      await receive(notification)
    case .serverRequest(let request):
      await receive(request)
    }
  }

  private func receive(_ notification: RPCNotification) async {
    switch notification.method {
    case "turn/started":
      do {
        guard case .turnStarted(let started) = try notification.decodedCodexNotification(),
          started.threadId == expectedThreadID,
          !started.turn.id.isEmpty
        else {
          throw IsolatedCodexTaskRuntimeError.protocolViolation
        }
        guard startedTurnIDs.isEmpty || startedTurnIDs.contains(started.turn.id) else {
          throw IsolatedCodexTaskRuntimeError.protocolViolation
        }
        startedTurnIDs.insert(started.turn.id)
      } catch {
        await fail(reason: "Codex emitted an invalid turn start event.")
      }
    case "item/started":
      guard let item = parseItem(notification.params) else {
        await fail(reason: "Codex emitted an invalid item event.")
        return
      }
      let correlation = item.correlation
      guard
        correlation.threadID == expectedThreadID,
        startedTurnIDs.contains(correlation.turnID),
        knownItems.count < maximumKnownItems
      else {
        await fail(reason: "Codex emitted an invalid item event.")
        return
      }
      knownItems[correlation] = item.type
    case "turn/completed":
      do {
        guard case .turnCompleted(let completed) = try notification.decodedCodexNotification()
        else {
          throw IsolatedCodexTaskRuntimeError.protocolViolation
        }
        guard let binding else {
          guard deferredTerminalNotifications.isEmpty else {
            throw IsolatedCodexTaskRuntimeError.protocolViolation
          }
          deferredTerminalNotifications.append(completed)
          return
        }
        guard completed.threadId == binding.threadID.rawValue,
          completed.turn.id == binding.turnID.rawValue
        else {
          throw IsolatedCodexTaskRuntimeError.bindingMismatch
        }
        await processTurnCompletion(completed)
      } catch {
        await fail(reason: "Codex emitted an invalid turn completion event.")
      }
    default:
      return
    }
  }

  private func receive(_ request: RPCServerRequest) async {
    guard Self.supportedApprovalMethods.contains(request.method) else {
      if Self.legacyApprovalMethods.contains(request.method) {
        await rejectLegacyApproval(request)
        await fail(reason: "Codex requested an approval without authoritative turn correlation.")
        return
      }
      try? await client.respond(
        to: request.id,
        errorCode: -32601,
        message: "Method not supported by Codex Bridge."
      )
      return
    }
    guard binding != nil else {
      guard deferredRequests.count < maximumPendingApprovals else {
        try? await client.respond(
          to: request.id,
          errorCode: -32000,
          message: "Codex Bridge approval capacity exceeded."
        )
        await fail(reason: "Codex approval capacity was exceeded.")
        return
      }
      deferredRequests.append(request)
      return
    }
    await processServerRequest(request)
  }

  private func processServerRequest(_ request: RPCServerRequest) async {
    guard let binding,
      let parsed = parseApproval(request),
      parsed.correlation.item.threadID == binding.threadID.rawValue,
      parsed.correlation.item.turnID == binding.turnID.rawValue,
      knownItems[parsed.correlation.item] == parsed.expectedItemType,
      !usedRequests.contains(parsed.correlation),
      usedRequests.count < maximumKnownItems,
      pendingApprovals.count < maximumPendingApprovals
    else {
      try? await client.respond(
        to: request.id,
        errorCode: -32602,
        message: "Approval request rejected by Codex Bridge."
      )
      await fail(reason: "Codex approval correlation was invalid.")
      return
    }
    usedRequests.insert(parsed.correlation)
    let approvalID = ApprovalID(
      rawValue: "apr_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    )
    pendingApprovals[approvalID] = PendingApproval(
      requestID: request.id,
      correlation: parsed.correlation,
      kind: parsed.kind
    )
    yield(.codexApprovalRequested(approvalID))
  }

  private func parseApproval(_ request: RPCServerRequest) -> (
    correlation: RequestCorrelation, kind: ApprovalKind, expectedItemType: String
  )? {
    guard let params = request.params?.objectValue,
      let threadID = params["threadId"]?.stringValue,
      let turnID = params["turnId"]?.stringValue,
      let itemID = params["itemId"]?.stringValue,
      !threadID.isEmpty,
      !turnID.isEmpty,
      !itemID.isEmpty
    else {
      return nil
    }
    let callbackID: String?
    if params["approvalId"] == .null || params["approvalId"] == nil {
      callbackID = nil
    } else {
      guard let value = params["approvalId"]?.stringValue, !value.isEmpty else { return nil }
      callbackID = value
    }
    let item = ItemCorrelation(threadID: threadID, turnID: turnID, itemID: itemID)
    let correlation = RequestCorrelation(
      method: request.method,
      item: item,
      callbackID: callbackID
    )
    switch request.method {
    case "item/commandExecution/requestApproval":
      return (correlation, .command, "commandExecution")
    case "item/fileChange/requestApproval":
      return (correlation, .fileChange, "fileChange")
    case "item/permissions/requestApproval":
      guard let permissions = params["permissions"], permissions.objectValue != nil else {
        return nil
      }
      return (correlation, .permissions(permissions), "commandExecution")
    default:
      return nil
    }
  }

  private func parseItem(_ params: JSONValue?) -> (correlation: ItemCorrelation, type: String)? {
    guard let object = params?.objectValue,
      let threadID = object["threadId"]?.stringValue,
      let turnID = object["turnId"]?.stringValue,
      let item = object["item"]?.objectValue,
      let itemID = item["id"]?.stringValue,
      let type = item["type"]?.stringValue,
      !itemID.isEmpty
    else {
      return nil
    }
    return (
      ItemCorrelation(threadID: threadID, turnID: turnID, itemID: itemID),
      type
    )
  }

  private func rejectLegacyApproval(_ request: RPCServerRequest) async {
    try? await client.respond(
      to: request.id,
      result: .object(["decision": .string("abort")])
    )
  }

  private func processTurnCompletion(_ completed: TurnNotification) async {
    guard let binding,
      completed.threadId == binding.threadID.rawValue,
      completed.turn.id == binding.turnID.rawValue
    else {
      await fail(reason: "Codex turn completion did not match the active turn.")
      return
    }
    guard approvalBarriers.isEmpty else {
      guard deferredTerminalNotifications.isEmpty else {
        await fail(reason: "Codex emitted duplicate turn completion events.")
        return
      }
      deferredTerminalNotifications.append(completed)
      return
    }
    switch completed.turn.status {
    case "completed":
      finish(with: .turnCompleted)
    case "interrupted":
      finish(with: .turnStopped)
    case "failed":
      finish(with: .failed(reason: "Codex reported that the turn failed."))
    default:
      await fail(reason: "Codex reported an invalid terminal turn status.")
    }
  }

  private func requireActive(_ requested: ExecutionBinding) throws {
    guard !terminal else { throw IsolatedCodexTaskRuntimeError.sessionEnded }
    guard binding == requested,
      startedTurnIDs.contains(requested.turnID.rawValue)
    else {
      throw IsolatedCodexTaskRuntimeError.bindingMismatch
    }
  }

  private func eventStreamEnded() async {
    guard !terminal else { return }
    await fail(reason: "Codex execution session ended unexpectedly.")
  }

  private func fail(reason: String) async {
    guard !terminal else { return }
    finish(with: .failed(reason: reason))
  }

  private func finish(with observation: TaskExecutionObservation) {
    guard !terminal else { return }
    terminal = true
    switch observationContinuation.yield(observation) {
    case .enqueued:
      break
    case .dropped, .terminated:
      break
    @unknown default:
      break
    }
    observationContinuation.finish()
    eventTask?.cancel()
    lifetimeTask?.cancel()
    Task { [client, onTermination, taskID] in
      await client.stop()
      await onTermination(taskID, self)
    }
  }

  private func yield(_ observation: TaskExecutionObservation) {
    switch observationContinuation.yield(observation) {
    case .enqueued:
      return
    case .dropped, .terminated:
      Task { await self.fail(reason: "Execution observation capacity was exceeded.") }
    @unknown default:
      Task { await self.fail(reason: "Execution observation capacity was exceeded.") }
    }
  }

  private static let supportedApprovalMethods: Set<String> = [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
  ]

  private static let legacyApprovalMethods: Set<String> = [
    "applyPatchApproval",
    "execCommandApproval",
  ]
}
