import BridgeCodexRPC
import XCTest

@testable import BridgeCodexService

final class CodexCompletionNormalizationTests: XCTestCase {
  func testAgentMessageContentPartsBecomeTheAuthoritativeConversationMessage() {
    let turn = try! JSONDecoder().decode(
      CodexTurn.self,
      from: Data(
        #"""
        {
          "id": "turn-1",
          "status": "completed",
          "error": null,
          "items": [{
            "id": "message-1",
            "type": "agentMessage",
            "content": [
              {"type": "output_text", "text": "最终回复第一段"},
              {"type": "output_text", "text": "最终回复第二段"}
            ]
          }],
          "itemsView": "full",
          "startedAt": null,
          "completedAt": null,
          "durationMs": null
        }
        """#.utf8
      )
    )

    let messages = ExecutionSession.agentMessages(from: turn)

    XCTAssertEqual(messages.map(\.content), ["最终回复第一段\n最终回复第二段"])
    XCTAssertEqual(ExecutionSession.finalMessage(turn), "最终回复第一段\n最终回复第二段")
  }
}
