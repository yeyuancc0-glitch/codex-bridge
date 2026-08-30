import BridgeCodexService
import BridgeIPC
import Foundation

extension BridgeServiceXPCController {
  static func conversationPage(
    taskID: String,
    entries: [TaskConversationBuffer.Entry]
  ) -> IPCTaskConversationPage {
    IPCTaskConversationPage(
      taskID: taskID,
      messages: entries.map { entry in
        IPCTaskConversationMessage(
          messageID: nil,
          key: entry.key,
          role: entry.role.rawValue,
          kind: entry.kind.rawValue,
          content: entry.content,
          toolName: entry.toolName,
          toolStatus: entry.toolStatus,
          toolArguments: entry.toolArguments,
          final: entry.isFinal
        )
      }
    )
  }

  static func encodePush(_ change: ConversationChange) -> Data? {
    let push = IPCTaskConversationPush(
      taskID: change.taskID.rawValue,
      key: change.key,
      role: change.role.rawValue,
      kind: change.kind.rawValue,
      delta: change.delta,
      baseContentLength: change.baseContentLength,
      fullContent: change.fullContent,
      final: change.final,
      toolName: change.toolName,
      toolStatus: change.toolStatus,
      toolArguments: change.toolArguments
    )
    guard let data = try? JSONEncoder().encode(push),
      data.count <= BridgeServiceIPC.maximumMessageBytes
    else {
      return nil
    }
    return data
  }
}
