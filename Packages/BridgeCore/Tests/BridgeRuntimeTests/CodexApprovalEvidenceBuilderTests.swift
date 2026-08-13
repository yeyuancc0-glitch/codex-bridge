import BridgeCodexRPC
import BridgeDomain
import XCTest

@testable import BridgeRuntime

final class CodexApprovalEvidenceBuilderTests: XCTestCase {
  func testRejectsDisplayCommandMismatchAndItemMismatch() throws {
    let item = try CodexApprovalWireDecoder.decodeItemStarted(commandItem())

    XCTAssertThrowsError(
      try build(request: commandRequest(command: "different", itemID: "item-1"), item: item)
    ) { error in
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }
    XCTAssertThrowsError(
      try build(request: commandRequest(command: "tool run", itemID: "item-2"), item: item)
    ) { error in
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }
    XCTAssertThrowsError(
      try build(
        request: commandRequest(command: "tool run", itemID: "item-1", mismatchedAction: true),
        item: item
      )
    ) { error in
      XCTAssertEqual(error as? IsolatedCodexTaskRuntimeError, .protocolViolation)
    }
  }

  private func build(
    request: RPCServerRequest,
    item: CodexApprovalItemEvidence
  ) throws -> CodexApprovalEvidence {
    try CodexApprovalEvidenceBuilder.build(
      approvalID: ApprovalID(rawValue: "approval-1"),
      request: CodexApprovalWireDecoder.decode(request),
      requestParameters: request.params ?? .null,
      itemEvidence: item,
      itemSourceDigest: try CodexApprovalEvidenceBuilder.canonicalSource(
        commandItem().params ?? .null
      ).digest,
      projectRoot: "/workspace"
    )
  }

  private func commandRequest(
    command: String,
    itemID: String,
    mismatchedAction: Bool = false
  ) -> RPCServerRequest {
    var parameters: [String: JSONValue] = [
      "threadId": .string("thread-1"),
      "turnId": .string("turn-1"),
      "itemId": .string(itemID),
      "startedAtMs": .integer(1),
      "command": .string(command),
      "cwd": .string("/workspace"),
    ]
    if mismatchedAction {
      parameters["commandActions"] = .array([
        .object([
          "type": .string("unknown"),
          "command": .string("different display action"),
        ])
      ])
    }
    return RPCServerRequest(
      id: .string("request-1"),
      method: "item/commandExecution/requestApproval",
      params: .object(parameters)
    )
  }

  private func commandItem() -> RPCNotification {
    RPCNotification(
      method: "item/started",
      params: .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-1"),
        "startedAtMs": .integer(1),
        "item": .object([
          "id": .string("item-1"),
          "type": .string("commandExecution"),
          "command": .string("tool run"),
          "commandActions": .array([]),
          "cwd": .string("/workspace"),
          "status": .string("inProgress"),
        ]),
      ])
    )
  }
}
