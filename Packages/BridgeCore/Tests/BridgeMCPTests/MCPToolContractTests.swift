import Foundation
import MCP
import XCTest

@testable import BridgeMCP

final class MCPToolContractTests: XCTestCase {
  func testServiceListAgentsSchemaDocumentsProviderCapabilitiesAndNetworkBoundary() throws {
    let definitions = MCPServiceToolCatalog(exposureMode: .readOnly).definitions
    let definition = try XCTUnwrap(
      definitions.first(where: { $0.name == MCPServiceToolName.listAgents.rawValue })
    )
    let agentProperties = try XCTUnwrap(
      definition.outputSchema?.objectValue?["properties"]?.objectValue?["agents"]?
        .objectValue?["items"]?
        .objectValue?["properties"]?.objectValue
    )
    let providerDescription = try XCTUnwrap(
      agentProperties["provider_id"]?.objectValue?["description"]?.stringValue
    )
    let capabilityDescription = try XCTUnwrap(
      agentProperties["effective_capabilities"]?.objectValue?["description"]?.stringValue
    )
    let networkDescription = try XCTUnwrap(
      agentProperties["network_enforcement"]?.objectValue?["description"]?.stringValue
    )

    XCTAssertTrue(providerDescription.contains("deepseek-harness"))
    XCTAssertTrue(capabilityDescription.contains("workspace.write_in_place"))
    XCTAssertTrue(capabilityDescription.contains("approval.one_shot"))
    XCTAssertTrue(capabilityDescription.contains("lifecycle.steer"))
    XCTAssertTrue(networkDescription.contains("does not guarantee"))

    let instructions = MCPServiceServerFactory.instructions(customInstructions: "")
    XCTAssertTrue(instructions.contains("provider_id=deepseek-harness"))
    XCTAssertTrue(instructions.contains("one-shot local approval"))
    XCTAssertTrue(instructions.contains("workspace-write"))
    XCTAssertTrue(instructions.contains("queued follow-up"))
    XCTAssertTrue(instructions.contains("network_enforcement"))
    XCTAssertTrue(instructions.contains("does not expose a Web search tool"))

    let submit = try XCTUnwrap(
      MCPServiceToolCatalog(exposureMode: .full).definitions.first(where: {
        $0.name == MCPServiceToolName.submitTask.rawValue
      })
    )
    XCTAssertTrue(
      submit.description?.contains("do not route tasks that require Web research") == true)
  }

  func testServiceCatalogPublishesStrictClosedSchemasAndExposureBoundaries() throws {
    let readOnly = MCPServiceToolCatalog(exposureMode: .readOnly).definitions
    let full = MCPServiceToolCatalog(exposureMode: .full).definitions

    XCTAssertTrue(readOnly.count < full.count)
    XCTAssertEqual(Set(full.map(\.name)), Set(MCPServiceToolName.allCases.map(\.rawValue)))
    XCTAssertTrue(readOnly.allSatisfy { $0.annotations.readOnlyHint == true })
    XCTAssertFalse(readOnly.contains { $0.name == MCPServiceToolName.submitTask.rawValue })
    XCTAssertTrue(full.contains { $0.name == MCPServiceToolName.submitTask.rawValue })
    let statusProperties = try XCTUnwrap(
      readOnly.first(where: { $0.name == MCPServiceToolName.bridgeStatus.rawValue })?
        .outputSchema?.objectValue?["properties"]?.objectValue
    )
    XCTAssertNotNil(statusProperties["codex_version"])
    XCTAssertNotNil(statusProperties["login_mode"])

    for definition in full {
      XCTAssertEqual(definition.annotations.openWorldHint, false)
      try assertObjectSchemasAreClosed(definition.inputSchema)
      try assertObjectSchemasAreClosed(XCTUnwrap(definition.outputSchema))
    }
  }

  func testModelSummaryDecodesPayloadWithoutDefaultEffort() throws {
    let data = Data(
      #"""
      {"model_id":"model","display_name":"Model","is_default":false,"reasoning_efforts":["medium"]}
      """#.utf8
    )
    let model = try JSONDecoder().decode(MCPModelSummary.self, from: data)

    XCTAssertNil(model.defaultReasoningEffort)
    let encoded = try JSONEncoder().encode(model)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("default_reasoning_effort"))
  }

  func testResultEncoderEnforcesConfiguredByteLimit() throws {
    let encoder = MCPToolResultEncoder(maximumBytes: 128)

    XCTAssertThrowsError(try encoder.encode(["value": String(repeating: "x", count: 256)])) {
      XCTAssertEqual(
        $0 as? MCPToolResultEncodingError,
        .resultTooLarge(maximumBytes: 128)
      )
    }
  }

  private func assertObjectSchemasAreClosed(
    _ value: Value,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    switch value {
    case .array(let values):
      for child in values {
        try assertObjectSchemasAreClosed(child, file: file, line: line)
      }
    case .object(let object):
      if object["type"] == "object" {
        switch object["additionalProperties"] {
        case .bool(false):
          break
        case .object(let schema):
          try assertObjectSchemasAreClosed(.object(schema), file: file, line: line)
        default:
          XCTFail("Object schema must bound additional properties.", file: file, line: line)
        }
      }
      for child in object.values {
        try assertObjectSchemasAreClosed(child, file: file, line: line)
      }
    default:
      break
    }
  }
}
