import BridgeCodexRPC
import BridgeDomain
import BridgeSecurity
import CryptoKit
import Foundation

extension ExecutionSession {
  func receive(_ event: AppServerEvent) async {
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
      await receiveTurnStarted(notification)
    case "item/started":
      await receiveItemStarted(notification)
    case "turn/plan/updated":
      await receiveSemanticNotification(notification)
    case "item/completed":
      guard let item = parseItem(notification.params), seenItems[item.key] == item.type else {
        await fail(
          code: "invalid_item_completed",
          summary: "Codex emitted an invalid item completion."
        )
        return
      }
      guard item.type == "commandExecution" || item.type == "fileChange" else { return }
      await receiveSemanticNotification(notification)
    case "item/agentMessage/delta":
      await receiveAgentMessageDelta(notification)
    case "turn/completed":
      await receiveTurnCompleted(notification)
    default:
      return
    }
  }

  private func receiveTurnStarted(_ notification: RPCNotification) async {
    do {
      guard case .turnStarted(let started) = try notification.decodedCodexNotification(),
        started.threadId == expectedThreadID,
        Self.isSafeWireIdentifier(started.turn.id),
        startedTurnIDs.isEmpty || startedTurnIDs.contains(started.turn.id)
      else {
        throw ExecutionServiceError.protocolViolation("turn started")
      }
      startedTurnIDs.insert(started.turn.id)
    } catch {
      await fail(
        code: "invalid_turn_started",
        summary: "Codex emitted an invalid Turn start event."
      )
    }
  }

  private func receiveItemStarted(_ notification: RPCNotification) async {
    guard let item = parseItem(notification.params),
      item.key.threadID == expectedThreadID,
      startedTurnIDs.contains(item.key.turnID),
      seenItems[item.key] == nil,
      seenItems.count < configuration.maximumKnownItems
    else {
      await fail(code: "invalid_item_started", summary: "Codex emitted an invalid item event.")
      return
    }
    seenItems[item.key] = item.type
    guard item.type == "commandExecution" || item.type == "fileChange" else { return }
    do {
      let evidence = try CodexApprovalWireDecoder.decodeItemStarted(notification)
      guard evidence.item == item.key, Self.isInProgress(evidence) else {
        throw ExecutionServiceError.protocolViolation("approval item")
      }
      knownItems[item.key] = evidence
    } catch {
      await fail(
        code: "invalid_approval_item",
        summary: "Codex emitted invalid approval item evidence."
      )
    }
  }

  private func receiveSemanticNotification(_ notification: RPCNotification) async {
    let sourceID: String
    let evidence: CodexSemanticExecutionEvidence
    do {
      sourceID = try Self.semanticSourceID(notification.params)
      if seenSemanticSources.contains(sourceID) { return }
      guard seenSemanticSources.count < configuration.maximumKnownItems else {
        throw ExecutionServiceError.protocolViolation("semantic event capacity")
      }
      evidence = try CodexApprovalWireDecoder.decodeSemanticNotification(notification)
    } catch {
      await fail(code: "invalid_semantic_event", summary: "Codex emitted invalid task progress.")
      return
    }

    do {
      let event = try makeEvent(evidence)
      seenSemanticSources.insert(sourceID)
      yield(event)
    } catch {
      await fail(code: "invalid_semantic_event", summary: "Codex emitted invalid task progress.")
    }
  }

  private func receiveAgentMessageDelta(_ notification: RPCNotification) async {
    do {
      guard case .agentMessageDelta(let delta) = try notification.decodedCodexNotification()
      else {
        throw ExecutionServiceError.protocolViolation("agent message delta")
      }
      try requireActiveEvidence(threadID: delta.threadId, turnID: delta.turnId)
      let event = try ExecutionAgentMessageDelta(
        threadID: delta.threadId,
        turnID: delta.turnId,
        itemID: delta.itemId,
        delta: delta.delta
      )
      yield(.agentMessageDelta(event))
    } catch {
      await fail(
        code: "invalid_agent_delta",
        summary: "Codex emitted an invalid agent message delta."
      )
    }
  }

  private func receiveTurnCompleted(_ notification: RPCNotification) async {
    do {
      guard case .turnCompleted(let completed) = try notification.decodedCodexNotification()
      else {
        throw ExecutionServiceError.protocolViolation("turn completed")
      }
      guard let binding else {
        guard deferredCompletion == nil else {
          throw ExecutionServiceError.protocolViolation("duplicate deferred completion")
        }
        deferredCompletion = completed
        return
      }
      guard completed.threadId == binding.threadID, completed.turn.id == binding.turnID else {
        throw ExecutionServiceError.bindingMismatch
      }
      await processTurnCompletion(completed)
    } catch {
      await fail(
        code: "invalid_turn_completed",
        summary: "Codex emitted an invalid Turn completion event."
      )
    }
  }

  private func receive(_ request: RPCServerRequest) async {
    guard Self.supportedApprovalMethods.contains(request.method) else {
      if Self.legacyApprovalMethods.contains(request.method) {
        await rejectLegacyApproval(request)
        await fail(
          code: "legacy_approval_unsupported",
          summary: "Codex requested an approval without authoritative Turn correlation."
        )
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
      guard deferredRequests.count < configuration.maximumPendingApprovals else {
        try? await client.respond(
          to: request.id,
          errorCode: -32000,
          message: "Codex Bridge approval capacity exceeded."
        )
        await fail(code: "approval_capacity", summary: "Codex approval capacity was exceeded.")
        return
      }
      deferredRequests.append(request)
      return
    }
    await processServerRequest(request)
  }

  func processServerRequest(_ rpcRequest: RPCServerRequest) async {
    guard let binding else {
      await rejectInvalidApproval(rpcRequest)
      return
    }
    do {
      let decoded = try CodexApprovalWireDecoder.decode(rpcRequest)
      let correlation = decoded.correlation
      let requestKey = ApprovalRequestKey(
        method: rpcRequest.method,
        threadID: correlation.item.threadID,
        turnID: correlation.item.turnID,
        itemID: correlation.item.itemID,
        callbackID: correlation.callbackID
      )
      guard correlation.item.threadID == binding.threadID,
        correlation.item.turnID == binding.turnID,
        let itemEvidence = knownItems[correlation.item],
        !usedApprovalRequests.contains(requestKey),
        usedApprovalRequests.count < configuration.maximumKnownItems,
        pendingApprovals.count < configuration.maximumPendingApprovals
      else {
        throw ExecutionServiceError.protocolViolation("approval correlation")
      }
      let id = "apr_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      let prepared = try ExecutionApprovalBuilder.build(
        approvalID: id,
        taskID: taskID,
        binding: binding,
        request: decoded,
        itemEvidence: itemEvidence,
        rawParameters: rpcRequest.params,
        projectRoot: projectRoot
      )
      usedApprovalRequests.insert(requestKey)
      pendingApprovals[id] = PendingApproval(
        rpcRequestID: rpcRequest.id,
        response: prepared.response,
        request: prepared.request
      )
      yield(.approvalRequested(prepared.request))
    } catch {
      await rejectInvalidApproval(rpcRequest)
    }
  }

  func processTurnCompletion(_ completed: TurnNotification) async {
    guard let binding,
      completed.threadId == binding.threadID,
      completed.turn.id == binding.turnID
    else {
      await fail(code: "turn_binding_mismatch", summary: "Codex Turn completion did not match.")
      return
    }
    guard approvalBarriers.isEmpty, pendingApprovals.isEmpty else {
      guard deferredCompletion == nil else {
        await fail(
          code: "duplicate_turn_completion",
          summary: "Codex emitted duplicate Turn completion events."
        )
        return
      }
      deferredCompletion = completed
      return
    }

    let messages = Self.agentMessages(from: completed.turn)
    if !messages.isEmpty {
      yield(.turnCompleted(messages: messages))
    }

    switch completed.turn.status {
    case "completed":
      finish(with: .completed(resultSummary: Self.finalMessage(completed.turn)))
    case "interrupted":
      finish(with: .interrupted)
    case "failed":
      finish(
        with: .failed(
          code: "codex_turn_failed",
          summary: "Codex reported that the Turn failed."
        )
      )
    default:
      await fail(code: "invalid_turn_status", summary: "Codex reported an invalid terminal status.")
    }
  }

  func eventStreamEnded() async {
    guard !terminal else { return }
    await fail(
      code: "execution_stream_ended",
      summary: "The Codex execution event stream ended unexpectedly."
    )
  }

  func fail(code: String, summary: String) async {
    guard !terminal else { return }
    finish(with: .failed(code: code, summary: summary))
  }

  private func finish(with event: ExecutionEvent) {
    guard !terminal else { return }
    terminal = true
    _ = continuation.yield(event)
    continuation.finish()
    eventTask?.cancel()
    lifetimeTask?.cancel()
    Task { [client, onTermination, taskID] in
      await client.stop()
      await onTermination(taskID, self)
    }
  }

  private func yield(_ event: ExecutionEvent) {
    switch continuation.yield(event) {
    case .enqueued:
      return
    case .dropped, .terminated:
      Task {
        await self.fail(
          code: "execution_event_capacity",
          summary: "The Codex execution event capacity was exceeded."
        )
      }
    @unknown default:
      Task {
        await self.fail(
          code: "execution_event_capacity",
          summary: "The Codex execution event capacity was exceeded."
        )
      }
    }
  }

  private func makeEvent(_ evidence: CodexSemanticExecutionEvidence) throws -> ExecutionEvent {
    switch evidence {
    case .planChanged(let plan):
      try requireActiveEvidence(threadID: plan.threadID, turnID: plan.turnID)
      let steps = plan.steps.map {
        OutboundContentSecurity.redacted($0.text, maximumUTF8Bytes: 4 * 1_024)
      }
      let currentStep =
        plan.steps.first(where: { $0.status == .inProgress })?.text
        ?? plan.steps.first(where: { $0.status == .pending })?.text
        ?? plan.steps.last?.text
        ?? plan.explanation
        ?? "Codex updated the task plan."
      return .planUpdated(
        currentStep: OutboundContentSecurity.redacted(
          currentStep,
          maximumUTF8Bytes: 4 * 1_024
        ),
        steps: steps
      )

    case .commandCompleted(let command):
      try requireKnownCompletedItem(command.item, type: "commandExecution")
      let status: ExecutionCommandStatus
      switch command.status {
      case .completed: status = .completed
      case .failed: status = .failed
      case .declined: status = .declined
      case .inProgress:
        throw ExecutionServiceError.protocolViolation("command completion status")
      }
      return .commandCompleted(
        displayCommand: OutboundContentSecurity.redacted(
          command.displayCommand,
          maximumUTF8Bytes: 8 * 1_024
        ),
        exitCode: command.exitCode,
        status: status
      )

    case .fileChangeCompleted(let file):
      try requireKnownCompletedItem(file.item, type: "fileChange")
      let status: ExecutionFileChangeStatus
      switch file.status {
      case .completed: status = .completed
      case .failed: status = .failed
      case .declined: status = .declined
      case .inProgress:
        throw ExecutionServiceError.protocolViolation("file completion status")
      }
      var paths: [String] = []
      for change in file.changes {
        paths.append(try ExecutionValidation.relativePath(change.path, root: projectRoot))
        if case .update(let movePath) = change.kind, let movePath {
          paths.append(try ExecutionValidation.relativePath(movePath, root: projectRoot))
        }
      }
      return .filesChanged(relativePaths: Array(Set(paths)).sorted(), status: status)
    }
  }

  private func requireActiveEvidence(threadID: String, turnID: String) throws {
    guard threadID == expectedThreadID, startedTurnIDs.contains(turnID) else {
      throw ExecutionServiceError.bindingMismatch
    }
  }

  private func requireKnownCompletedItem(
    _ item: CodexApprovalItemKey,
    type: String
  ) throws {
    try requireActiveEvidence(threadID: item.threadID, turnID: item.turnID)
    guard seenItems[item] == type, knownItems[item] != nil else {
      throw ExecutionServiceError.protocolViolation("completed item")
    }
  }

  private func parseItem(_ params: JSONValue?) -> (key: CodexApprovalItemKey, type: String)? {
    guard let object = params?.objectValue,
      let threadID = object["threadId"]?.stringValue,
      let turnID = object["turnId"]?.stringValue,
      let item = object["item"]?.objectValue,
      let itemID = item["id"]?.stringValue,
      let type = item["type"]?.stringValue,
      Self.isSafeWireIdentifier(threadID),
      Self.isSafeWireIdentifier(turnID),
      Self.isSafeWireIdentifier(itemID),
      !type.isEmpty,
      type.utf8.count <= 64,
      !type.contains("\0")
    else {
      return nil
    }
    return (
      CodexApprovalItemKey(threadID: threadID, turnID: turnID, itemID: itemID),
      type
    )
  }

  private func rejectInvalidApproval(_ request: RPCServerRequest) async {
    try? await client.respond(
      to: request.id,
      errorCode: -32602,
      message: "Approval request rejected by Codex Bridge."
    )
    await fail(
      code: "invalid_approval_request",
      summary: "Codex emitted an invalid approval request."
    )
  }

  private func rejectLegacyApproval(_ request: RPCServerRequest) async {
    try? await client.respond(
      to: request.id,
      result: .object(["decision": .string("abort")])
    )
  }

  private static func semanticSourceID(_ source: JSONValue?) throws -> String {
    guard let source else {
      throw ExecutionServiceError.protocolViolation("semantic source")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SHA256.hash(data: try encoder.encode(source)).map {
      String(format: "%02x", $0)
    }.joined()
  }

  private static func agentMessages(from turn: CodexTurn) -> [ExecutionAgentMessage] {
    var messages: [ExecutionAgentMessage] = []
    for item in turn.items {
      guard let object = item.objectValue,
        object["type"]?.stringValue == "agentMessage",
        let itemID = object["id"]?.stringValue,
        let text = object["text"]?.stringValue,
        let message = try? ExecutionAgentMessage(
          key: "agent:" + itemID,
          role: .agent,
          content: OutboundContentSecurity.redacted(text, maximumUTF8Bytes: 256 * 1_024)
        )
      else { continue }
      messages.append(message)
      if messages.count >= 256 { break }
    }
    return messages
  }

  private static func finalMessage(_ turn: CodexTurn) -> String {
    for item in turn.items.reversed() {
      guard let object = item.objectValue,
        object["type"]?.stringValue == "agentMessage",
        let text = object["text"]?.stringValue
      else { continue }
      let result = OutboundContentSecurity.redacted(text, maximumUTF8Bytes: 32 * 1_024)
      if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return result
      }
    }
    return "Codex completed the task."
  }

  private static func isInProgress(_ evidence: CodexApprovalItemEvidence) -> Bool {
    switch evidence {
    case .commandExecution(let value): value.status == .inProgress
    case .fileChange(let value): value.status == .inProgress
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
