import BridgeAgentCore
import BridgeDomain
import XCTest

@testable import BridgeOpenCodeACP

final class OpenCodeACPEventNormalizerTests: XCTestCase {
  func testNormalizesContentToolsPermissionAndCompletion() async throws {
    let normalizer = try makeNormalizer()

    let first = try await normalizer.normalize(
      .notification(Self.messageNotification(text: "Hello "))
    )
    let second = try await normalizer.normalize(
      .notification(Self.messageNotification(text: "world"))
    )
    let toolPending = try await normalizer.normalize(
      .notification(Self.toolNotification(status: "pending"))
    )
    let toolUnknown = try await normalizer.normalize(
      .notification(Self.toolNotification(status: "future_status"))
    )
    let toolCompleted = try await normalizer.normalize(
      .notification(Self.toolNotification(status: "completed"))
    )
    let denied = try await normalizer.normalize(
      .permissionDenied(try Self.permissionRequest())
    )

    guard case .content(let firstUpdate)? = first?.event,
      case .content(let secondUpdate)? = second?.event,
      case .tool(let pendingUpdate)? = toolPending?.event,
      case .tool(let unknownUpdate)? = toolUnknown?.event,
      case .tool(let completedUpdate)? = toolCompleted?.event,
      case .approvalAutomaticallyDenied(let toolCallID)? = denied?.event
    else {
      return XCTFail("Expected normalized OpenCode events")
    }

    XCTAssertEqual(firstUpdate.mode, .delta)
    XCTAssertEqual(firstUpdate.content, "Hello ")
    XCTAssertEqual(firstUpdate.baseContentLength, 0)
    XCTAssertEqual(secondUpdate.content, "world")
    XCTAssertEqual(secondUpdate.baseContentLength, 6)
    XCTAssertEqual(pendingUpdate.status, .pending)
    XCTAssertEqual(unknownUpdate.status, .pending)
    XCTAssertEqual(completedUpdate.status, .completed)
    XCTAssertEqual(toolCallID, "tool-1")

    let finalized = try await normalizer.finalizeContent()
    XCTAssertEqual(finalized.count, 1)
    guard case .content(let finalUpdate) = finalized[0].event else {
      return XCTFail("Expected a final authoritative content update")
    }
    XCTAssertEqual(finalUpdate.mode, .full)
    XCTAssertEqual(finalUpdate.content, "Hello world")
    XCTAssertTrue(finalUpdate.isFinal)
    XCTAssertTrue(finalUpdate.authoritative)

    let completed = try await normalizer.completed(stopReason: "end_turn")
    guard case .completed(let summary, let stopReason) = completed.event else {
      return XCTFail("Expected completion")
    }
    XCTAssertEqual(summary, "OpenCode turn completed.")
    XCTAssertEqual(stopReason, "end_turn")
  }

  func testRejectsWrongSession() async throws {
    let normalizer = try makeNormalizer()
    let notification = OpenCodeACPNotification(
      method: "session/update",
      params: .object([
        "sessionId": .string("other-session"),
        "update": .object([
          "sessionUpdate": .string("agent_message_chunk"),
          "content": .object([
            "type": .string("text"),
            "text": .string("unexpected"),
          ]),
        ]),
      ])
    )

    do {
      _ = try await normalizer.normalize(.notification(notification))
      XCTFail("Expected a session mismatch")
    } catch {
      XCTAssertEqual(error as? OpenCodeACPError, .sessionMismatch)
    }
  }

  func testBoundsDistinctContentStreamsWithoutRetainingRejectedState() async throws {
    let normalizer = try makeNormalizer()
    for index in 0..<64 {
      _ = try await normalizer.normalize(
        .notification(
          Self.messageNotification(text: "x", messageID: "message-\(index)")
        )
      )
    }

    do {
      _ = try await normalizer.normalize(
        .notification(Self.messageNotification(text: "overflow", messageID: "message-64"))
      )
      XCTFail("Expected the content stream bound to reject the update")
    } catch {
      XCTAssertEqual(error as? OpenCodeACPError, .oversizedFrame)
    }
    let finalized = try await normalizer.finalizeContent()
    XCTAssertEqual(finalized.count, 64)
  }

  func testBoundsDistinctToolCalls() async throws {
    let normalizer = try makeNormalizer()
    for index in 0..<256 {
      _ = try await normalizer.normalize(
        .notification(
          Self.toolNotification(status: "pending", toolCallID: "tool-\(index)")
        )
      )
    }

    do {
      _ = try await normalizer.normalize(
        .notification(Self.toolNotification(status: "pending", toolCallID: "tool-256"))
      )
      XCTFail("Expected the tool bound to reject the update")
    } catch {
      XCTAssertEqual(error as? OpenCodeACPError, .oversizedFrame)
    }
  }

  private func makeNormalizer() throws -> OpenCodeACPEventNormalizer {
    let binding = try AgentBinding(
      providerID: .openCode,
      installationID: AgentInstallationID(rawValue: "opencode-test"),
      providerSessionID: "session-1"
    )
    return OpenCodeACPEventNormalizer(
      taskID: TaskID(rawValue: "task-1"),
      binding: binding
    )
  }

  private static func messageNotification(
    text: String,
    messageID: String = "message-1"
  ) -> OpenCodeACPNotification {
    OpenCodeACPNotification(
      method: "session/update",
      params: .object([
        "sessionId": .string("session-1"),
        "update": .object([
          "sessionUpdate": .string("agent_message_chunk"),
          "messageId": .string(messageID),
          "content": .object([
            "type": .string("text"),
            "text": .string(text),
          ]),
        ]),
      ])
    )
  }

  private static func toolNotification(
    status: String,
    toolCallID: String = "tool-1"
  ) -> OpenCodeACPNotification {
    OpenCodeACPNotification(
      method: "session/update",
      params: .object([
        "sessionId": .string("session-1"),
        "update": .object([
          "sessionUpdate": .string("tool_call_update"),
          "toolCallId": .string(toolCallID),
          "title": .string("Read project file"),
          "kind": .string("read"),
          "status": .string(status),
          "locations": .array([
            .object(["path": .string("/tmp/project/file.swift")])
          ]),
        ]),
      ])
    )
  }

  private static func permissionRequest() throws -> OpenCodeACPPermissionRequest {
    OpenCodeACPPermissionRequest(
      requestID: .string("permission-1"),
      sessionID: "session-1",
      toolCallID: "tool-1",
      title: "Run command",
      kind: "execute",
      rawInput: .object(["command": .string("git status")]),
      options: [
        try AgentApprovalOption(
          id: "reject",
          name: "Reject",
          kind: "reject_once"
        )
      ]
    )
  }
}
