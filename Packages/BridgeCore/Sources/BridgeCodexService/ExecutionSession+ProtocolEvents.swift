import BridgeCodexRPC

extension ExecutionSession {
  func receiveTurnStarted(_ notification: RPCNotification) async {
    do {
      guard case .turnStarted(let started) = try notification.decodedCodexNotification(),
        let expectedThreadID,
        let eventBinding = try? ExecutionBinding(
          threadID: started.threadId,
          turnID: started.turn.id
        )
      else {
        throw ExecutionServiceError.protocolViolation("turn started")
      }
      if eventBinding.threadID == expectedThreadID {
        guard startedTurnIDs.isEmpty || startedTurnIDs.contains(eventBinding.turnID) else {
          throw ExecutionServiceError.protocolViolation("primary turn started")
        }
        startedTurnIDs.insert(eventBinding.turnID)
        return
      }
      guard !startedTurnIDs.isEmpty,
        collaborationBindings.count < configuration.maximumKnownItems
          || collaborationBindings.contains(eventBinding)
      else {
        throw ExecutionServiceError.protocolViolation("collaboration turn started")
      }
      collaborationBindings.insert(eventBinding)
    } catch {
      await fail(
        code: "invalid_turn_started",
        summary: "Codex emitted an invalid Turn start event."
      )
    }
  }

  func receiveItemStarted(_ notification: RPCNotification) async {
    guard let item = parseItem(notification.params),
      isKnownBinding(threadID: item.key.threadID, turnID: item.key.turnID),
      seenItems[item.key] == nil,
      seenItems.count < configuration.maximumKnownItems
    else {
      await fail(code: "invalid_item_started", summary: "Codex emitted an invalid item event.")
      return
    }
    seenItems[item.key] = item.type
    if item.type == "mcpToolCall" || item.type == "dynamicToolCall" {
      guard isPrimaryBinding(threadID: item.key.threadID, turnID: item.key.turnID) else {
        return
      }
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

  func isKnownBinding(threadID: String, turnID: String) -> Bool {
    guard let value = try? ExecutionBinding(threadID: threadID, turnID: turnID) else {
      return false
    }
    return isKnownBinding(value)
  }

  func isKnownBinding(_ value: ExecutionBinding) -> Bool {
    isPrimaryBinding(threadID: value.threadID, turnID: value.turnID)
      || collaborationBindings.contains(value)
  }

  func isPrimaryBinding(threadID: String, turnID: String) -> Bool {
    threadID == expectedThreadID && startedTurnIDs.contains(turnID)
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
      if case .planChanged(let plan) = evidence,
        !isPrimaryBinding(threadID: plan.threadID, turnID: plan.turnID)
      {
        try requireActiveEvidence(threadID: plan.threadID, turnID: plan.turnID)
        seenSemanticSources.insert(sourceID)
        return
      }
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
