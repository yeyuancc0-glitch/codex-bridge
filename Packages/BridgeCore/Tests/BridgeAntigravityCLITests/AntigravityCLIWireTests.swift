import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIWireTests: XCTestCase {
  func testDecodesInitializationStepAndResultFrames() throws {
    let initialization = try AntigravityWireCodec.decode(
      AntigravityCLITestSupport.initializationFrame(cwd: "/tmp/project")
    )
    XCTAssertEqual(initialization.event, "init")
    XCTAssertEqual(initialization.conversationID, "conversation-1")
    XCTAssertEqual(initialization.initialization?.cwd, "/tmp/project")
    XCTAssertEqual(initialization.initialization?.tools, ["read_file", "search"])
    XCTAssertEqual(initialization.initialization?.permissionMode, "request-review")
    XCTAssertEqual(initialization.initialization?.model, "gemini-test")

    let step = try AntigravityWireCodec.decode(
      AntigravityCLITestSupport.stepUpdateFrame(
        stepType: "agent_response"
      )
    )
    XCTAssertEqual(step.event, "step_update")
    XCTAssertEqual(step.stepUpdate?.conversationID, "conversation-1")
    XCTAssertEqual(step.stepUpdate?.stepIndex, 0)
    XCTAssertEqual(step.stepUpdate?.textDelta, "Hello")

    let result = try AntigravityWireCodec.decode(
      try AntigravityCLITestSupport.resultFrame(totalTokens: 7)
    )
    XCTAssertEqual(result.event, "result")
    XCTAssertEqual(result.result?.status, "SUCCESS")
    XCTAssertEqual(result.result?.response, "Done.")
    XCTAssertEqual(result.result?.usage?.inputTokens, 1)
    XCTAssertEqual(result.result?.usage?.totalTokens, 7)
  }

  func testDecodesNestedToolAndSubagentPayloads() throws {
    let frame = AntigravityCLITestSupport.data(
      """
      {"event":"step_update","step_update":{"conversation_id":"conversation-1","step_index":3,"state":"DONE","step_type":"tool","tool_name":"read_file","text_delta":null,"duration_seconds":1.25,"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5},"tool_info":{"name":"read_file","parameters":{"path":"Sources/main.swift","line":12},"output":"ok","error":null},"subagent_info":{"subagents":[{"type_name":"reviewer","role":"review","conversation_id":"sub-1","log_uri":"file:///tmp/log","workspace_uris":["file:///tmp/project"]}]}}}
      """
    )

    let envelope = try AntigravityWireCodec.decode(frame)
    let update = try XCTUnwrap(envelope.stepUpdate)
    XCTAssertEqual(update.toolInfo?.name, "read_file")
    XCTAssertEqual(update.toolInfo?.parameters?["path"]?.stringValue, "Sources/main.swift")
    XCTAssertEqual(update.toolInfo?.parameters?["line"]?.intValue, 12)
    XCTAssertEqual(update.usage?.totalTokens, 5)
    let subagent = try XCTUnwrap(update.subagentInfo?.subagents?.first)
    XCTAssertEqual(subagent.typeName, "reviewer")
    XCTAssertEqual(subagent.role, "review")
    XCTAssertEqual(subagent.workspaceURIs, ["file:///tmp/project"])
  }

  func testEncodesTrimmedUserMessageWithStableWireShape() throws {
    let encoded = try AntigravityWireCodec.encodeUserMessage("  inspect the project  \n")
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    XCTAssertEqual(object["event"] as? String, "user")
    XCTAssertEqual(
      (object["message"] as? [String: Any])?["content"] as? String, "inspect the project")
    XCTAssertFalse(encoded.contains(0x0A))
  }

  func testRejectsMalformedAndOversizedWireFrames() throws {
    XCTAssertThrowsError(
      try AntigravityWireCodec.decode(Data("not-json".utf8))
    ) { error in
      XCTAssertEqual(error as? AntigravityCLIError, .invalidMessage)
    }
    XCTAssertThrowsError(
      try AntigravityWireCodec.decode(Data("{}".utf8))
    ) { error in
      XCTAssertEqual(error as? AntigravityCLIError, .invalidMessage)
    }
    XCTAssertThrowsError(
      try AntigravityWireCodec.decode(Data("12345".utf8), maximumBytes: 4)
    ) { error in
      XCTAssertEqual(error as? AntigravityCLIError, .oversizedFrame)
    }
    XCTAssertThrowsError(
      try AntigravityWireCodec.encodeUserMessage("secret\0text")
    ) { error in
      XCTAssertEqual(error as? AntigravityCLIError, .invalidMessage)
    }
    XCTAssertThrowsError(
      try AntigravityWireCodec.encodeUserMessage("long", maximumBytes: 3)
    ) { error in
      XCTAssertEqual(error as? AntigravityCLIError, .invalidMessage)
    }
  }

  func testJSONValuePreservesTypesAndProducesSortedKeys() throws {
    let value: AntigravityJSONValue = .object([
      "z": .bool(true),
      "a": .array([.integer(4), .null, .number(1.5)]),
    ])
    let encoded = try XCTUnwrap(value.encodedString())
    XCTAssertEqual(encoded, #"{"a":[4,null,1.5],"z":true}"#)
    let decoded = try JSONDecoder().decode(
      AntigravityJSONValue.self,
      from: Data(encoded.utf8)
    )
    XCTAssertEqual(decoded, value)
  }
}
