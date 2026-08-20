import BridgeCodexRPC

extension ExecutionSession {
  func receiveTurnStarted(_ notification: RPCNotification) async {
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

  func receiveItemStarted(_ notification: RPCNotification) async {
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
    if item.type == "mcpToolCall" || item.type == "dynamicToolCall" {
      guard let call = Self.toolCall(from: notification.params) else {
        await fail(
          code: "invalid_tool_call_item",
          summary: "Codex emitted an invalid tool call item."
        )
        return
      }
      yield(.toolCall(call))
      return
    }
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

  func receiveSemanticNotification(_ notification: RPCNotification) async {
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
}
