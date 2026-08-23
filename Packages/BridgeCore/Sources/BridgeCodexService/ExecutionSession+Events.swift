import BridgeCodexRPC

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
      await receiveSemanticNotification(notification)
    case "item/agentMessage/delta":
      await receiveAgentMessageDelta(notification)
    case "item/reasoning/textDelta":
      await receiveReasoningTextDelta(notification)
    case "item/mcpToolCall/progress":
      await receiveMcpToolCallProgress(notification)
    case "turn/completed":
      await receiveTurnCompleted(notification)
    default:
      return
    }
  }
}
