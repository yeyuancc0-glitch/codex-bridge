import BridgeIPC
import BridgePlatform
import XCTest

final class BridgeIPCGoldenContractTests: XCTestCase {
  func testRequestFixtureMatchesSwiftCodec() throws {
    let fixture = try fixtureData(named: "request-status")
    let wire = try BridgeWireMessage.decode(fixture)
    XCTAssertEqual(wire.kind, .request)
    let request = try BridgeServiceIPCCodec.decodeRequest(wire.message)
    XCTAssertEqual(request.requestID, "fixture-status-1")
    XCTAssertEqual(request.operation, .status)
    XCTAssertNil(request.payload)

    let encoded = try BridgeWireMessage(
      kind: .request,
      message: BridgeServiceIPCCodec.emptyRequest(
        operation: .status,
        requestID: "fixture-status-1"
      )
    ).encoded()
    XCTAssertEqual(try canonicalJSON(encoded), try canonicalJSON(fixture))
  }

  func testResponseFixtureMatchesSwiftCodec() throws {
    let fixture = try fixtureData(named: "response-success")
    let wire = try BridgeWireMessage.decode(fixture)
    XCTAssertEqual(wire.kind, .response)
    let response = try BridgeServiceIPCCodec.decodeResponse(
      IPCMutationResponse.self,
      data: wire.message,
      requestID: "fixture-mutation-1"
    )
    XCTAssertEqual(response, IPCMutationResponse())

    let encoded = try BridgeWireMessage(
      kind: .response,
      message: BridgeServiceIPCCodec.emptySuccess(requestID: "fixture-mutation-1")
    ).encoded()
    XCTAssertEqual(try canonicalJSON(encoded), try canonicalJSON(fixture))
  }

  func testEventFixtureMatchesConversationPushContract() throws {
    let fixture = try fixtureData(named: "event-conversation-push")
    let wire = try BridgeWireMessage.decode(fixture)
    XCTAssertEqual(wire.kind, .event)
    let event = try JSONDecoder().decode(IPCTaskConversationPush.self, from: wire.message)
    XCTAssertEqual(event.taskID, "task-fixture-1")
    XCTAssertEqual(event.delta, "hello")
    XCTAssertFalse(event.final)

    let encodedEvent = try JSONEncoder.sorted.encode(
      IPCTaskConversationPush(
        taskID: "task-fixture-1",
        key: "agent-1",
        role: "assistant",
        delta: "hello",
        baseContentLength: 0,
        fullContent: nil,
        final: false
      )
    )
    let encoded = try BridgeWireMessage(kind: .event, message: encodedEvent).encoded()
    XCTAssertEqual(try canonicalJSON(encoded), try canonicalJSON(fixture))
  }

  func testWireMessageRejectsUnknownTypeAndNonObjectPayload() throws {
    XCTAssertThrowsError(
      try BridgeWireMessage.decode(Data(#"{"message":{},"type":"unknown"}"#.utf8))
    ) { error in
      XCTAssertEqual(error as? BridgeWireMessage.MessageError, .unsupportedType("unknown"))
    }
    XCTAssertThrowsError(
      try BridgeWireMessage(kind: .request, message: Data("[]".utf8)).encoded()
    ) { error in
      XCTAssertEqual(error as? BridgeWireMessage.MessageError, .invalidMessage)
    }
  }

  private func fixtureData(named name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    )
    return try Data(contentsOf: url)
  }

  private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}

extension JSONEncoder {
  fileprivate static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
