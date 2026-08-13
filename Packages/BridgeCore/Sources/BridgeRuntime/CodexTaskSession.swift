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
    let evidence: CodexApprovalEvidence
  }

  private struct KnownItem: Sendable {
    let type: String
    let evidence: CodexApprovalItemEvidence
    let sourceDigest: String
  }

  nonisolated let observations: AsyncStream<TaskExecutionObservation>
  let client: CodexAppServerClient

  private let taskID: TaskID
  private let observationContinuation: AsyncStream<TaskExecutionObservation>.Continuation
  private let maximumPendingApprovals: Int
  private let maximumKnownItems: Int
  private let maximumKnownItemEvidenceBytes: Int
  private let maximumSessionNanoseconds: UInt64
  private let projectRoot: String
  private let onTermination: @Sendable (TaskID, CodexTaskSession) async -> Void
  private var eventTask: Task<Void, Never>?
  private var lifetimeTask: Task<Void, Never>?
  private var expectedThreadID: String?
  private var binding: ExecutionBinding?
  private var startedTurnIDs: Set<String> = []
  private var seenItems: Set<ItemCorrelation> = []
  private var knownItems: [ItemCorrelation: KnownItem] = [:]
  private var knownItemEvidenceBytes = 0
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
    maximumKnownItemEvidenceBytes: Int,
    maximumSessionNanoseconds: UInt64,
    projectRoot: String,
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
    self.maximumKnownItemEvidenceBytes = maximumKnownItemEvidenceBytes
    self.maximumSessionNanoseconds = maximumSessionNanoseconds
    self.projectRoot = projectRoot
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

  func approvalEvidence(_ approvalID: ApprovalID) -> CodexApprovalEvidence? {
    pendingApprovals[approvalID]?.evidence
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
        !seenItems.contains(correlation),
        seenItems.count < maximumKnownItems
      else {
        await fail(reason: "Codex emitted an invalid item event.")
        return
      }
      seenItems.insert(correlation)
      guard item.type == "commandExecution" || item.type == "fileChange" else { return }
      let evidence: CodexApprovalItemEvidence
      let source: (digest: String, byteCount: Int)
      do {
        evidence = try CodexApprovalWireDecoder.decodeItemStarted(notification)
        guard Self.itemCorrelation(evidence.item) == correlation,
          Self.isInProgress(evidence)
        else {
          throw IsolatedCodexTaskRuntimeError.protocolViolation
        }
        source = try CodexApprovalEvidenceBuilder.canonicalSource(
          notification.params ?? .null
        )
      } catch {
        await fail(reason: "Codex emitted invalid approval item evidence.")
        return
      }
      guard source.byteCount <= maximumKnownItemEvidenceBytes - knownItemEvidenceBytes else {
        await fail(reason: "Codex approval evidence capacity was exceeded.")
        return
      }
      knownItems[correlation] = KnownItem(
        type: item.type,
        evidence: evidence,
        sourceDigest: source.digest
      )
      knownItemEvidenceBytes += source.byteCount
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
    guard let binding else {
      await rejectInvalidApproval(request)
      return
    }
    let parsed:
      (
        correlation: RequestCorrelation, request: CodexApprovalRequest, expectedItemType: String
      )
    do {
      parsed = try parseApproval(request)
    } catch {
      await rejectInvalidApproval(request)
      return
    }
    guard
      parsed.correlation.item.threadID == binding.threadID.rawValue,
      parsed.correlation.item.turnID == binding.turnID.rawValue,
      let knownItem = knownItems[parsed.correlation.item],
      knownItem.type == parsed.expectedItemType,
      !usedRequests.contains(parsed.correlation),
      usedRequests.count < maximumKnownItems,
      pendingApprovals.count < maximumPendingApprovals
    else {
      await rejectInvalidApproval(request)
      return
    }
    let approvalID = ApprovalID(
      rawValue: "apr_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    )
    let evidence: CodexApprovalEvidence
    do {
      evidence = try CodexApprovalEvidenceBuilder.build(
        approvalID: approvalID,
        request: parsed.request,
        requestParameters: request.params ?? .null,
        itemEvidence: knownItem.evidence,
        itemSourceDigest: knownItem.sourceDigest,
        projectRoot: projectRoot
      )
    } catch {
      await rejectInvalidApproval(request)
      return
    }
    usedRequests.insert(parsed.correlation)
    pendingApprovals[approvalID] = PendingApproval(
      requestID: request.id,
      correlation: parsed.correlation,
      kind: responseKind(parsed.request, rawParameters: request.params),
      evidence: evidence
    )
    yield(.codexApprovalRequested(approvalID))
  }

  private func parseApproval(_ request: RPCServerRequest) throws -> (
    correlation: RequestCorrelation, request: CodexApprovalRequest, expectedItemType: String
  ) {
    let decoded = try CodexApprovalWireDecoder.decode(request)
    let key = decoded.correlation.item
    let item = ItemCorrelation(threadID: key.threadID, turnID: key.turnID, itemID: key.itemID)
    let correlation = RequestCorrelation(
      method: request.method,
      item: item,
      callbackID: decoded.correlation.callbackID
    )
    let expectedItemType =
      switch decoded {
      case .command, .permissions: "commandExecution"
      case .fileChange: "fileChange"
      }
    return (correlation, decoded, expectedItemType)
  }

  private func responseKind(
    _ request: CodexApprovalRequest,
    rawParameters: JSONValue?
  ) -> ApprovalKind {
    switch request {
    case .command: .command
    case .fileChange: .fileChange
    case .permissions:
      .permissions(rawParameters?.objectValue?["permissions"] ?? .object([:]))
    }
  }

  private func rejectInvalidApproval(_ request: RPCServerRequest) async {
    try? await client.respond(
      to: request.id,
      errorCode: -32602,
      message: "Approval request rejected by Codex Bridge."
    )
    await fail(reason: "Codex approval correlation was invalid.")
  }

  private func parseItem(_ params: JSONValue?) -> (correlation: ItemCorrelation, type: String)? {
    guard let object = params?.objectValue,
      let threadID = object["threadId"]?.stringValue,
      let turnID = object["turnId"]?.stringValue,
      let item = object["item"]?.objectValue,
      let itemID = item["id"]?.stringValue,
      let type = item["type"]?.stringValue,
      Self.isValidWireIdentifier(threadID),
      Self.isValidWireIdentifier(turnID),
      Self.isValidWireIdentifier(itemID),
      !type.isEmpty,
      type.utf8.count <= 64,
      !type.contains("\0")
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
    guard pendingApprovals.isEmpty else {
      await fail(reason: "Codex completed a turn with unresolved approval requests.")
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

  private static func itemCorrelation(_ key: CodexApprovalItemKey) -> ItemCorrelation {
    ItemCorrelation(threadID: key.threadID, turnID: key.turnID, itemID: key.itemID)
  }

  private static func isInProgress(_ evidence: CodexApprovalItemEvidence) -> Bool {
    switch evidence {
    case .commandExecution(let command): command.status == .inProgress
    case .fileChange(let change): change.status == .inProgress
    }
  }

  private static func isValidWireIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= CodexApprovalWireLimits.identifierBytes
      && !value.contains("\0")
  }

}
