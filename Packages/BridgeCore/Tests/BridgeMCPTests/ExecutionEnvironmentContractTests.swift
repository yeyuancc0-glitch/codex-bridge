import BridgeMCP
import Foundation
import MCP
import XCTest

final class ExecutionEnvironmentContractTests: XCTestCase {
  func testExecutionEnvironmentAdditiveFieldsEncodeAndLegacyPayloadStillDecodes() throws {
    let environment = MCPExecutionEnvironment(
      bridgeSandbox: "unknown",
      scope: "direct_command",
      sandboxExec: "available",
      nestedSandbox: "restricted",
      loopback: "restricted",
      childNetworkPolicy: "denied",
      xcodebuildNestedSandbox: "unavailable",
      loopbackBind: "unavailable",
      limitations: ["loopback_bind_unavailable"]
    )

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(environment)) as? [String: Any]
    )
    XCTAssertEqual(object["xcodebuild_nested_sandbox"] as? String, "unavailable")
    XCTAssertEqual(object["loopback_bind"] as? String, "unavailable")
    XCTAssertEqual(object["scope"] as? String, "direct_command")

    let legacy = try JSONDecoder().decode(
      MCPExecutionEnvironment.self,
      from: Data(
        #"{"bridge_sandbox":"unknown","sandbox_exec":"available","nested_sandbox":"available","loopback":"available","limitations":[]}"#
          .utf8
      )
    )
    XCTAssertNil(legacy.xcodebuildNestedSandbox)
    XCTAssertNil(legacy.loopbackBind)
    XCTAssertNil(legacy.scope)
  }

  func testPublishedSchemasExposeSpecificNestedSandboxAndLoopbackCapabilities() throws {
    let definitions = Dictionary(
      uniqueKeysWithValues: MCPServiceToolCatalog(exposureMode: .full).definitions.map {
        ($0.name, $0)
      }
    )
    let status = try environmentProperties(
      tool: "bridge_status",
      definitions: definitions
    )
    let read = try environmentProperties(
      tool: "direct_read_command",
      definitions: definitions
    )

    for properties in [status, read] {
      XCTAssertNotNil(properties["xcodebuild_nested_sandbox"])
      XCTAssertNotNil(properties["loopback_bind"])
      XCTAssertNotNil(properties["scope"])
    }

  }

  private func environmentProperties(
    tool: String,
    definitions: [String: Tool]
  ) throws -> [String: Value] {
    let output = try XCTUnwrap(definitions[tool]?.outputSchema?.objectValue)
    let properties = try XCTUnwrap(output["properties"]?.objectValue)
    return try XCTUnwrap(
      properties["execution_environment"]?.objectValue?["properties"]?.objectValue
    )
  }
}
