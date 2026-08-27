import Foundation
import MCP
import XCTest

@testable import BridgeMCP

final class MCPAntigravityContractTests: XCTestCase {
  func testSubmitTaskSchemaPublishesAntigravityReadOnlyBoundary() throws {
    let definitions = MCPServiceToolCatalog(exposureMode: .full).definitions
    let submit = try XCTUnwrap(definitions.first { $0.name == "submit_task" })
    let properties = try XCTUnwrap(
      submit.inputSchema.objectValue?["properties"]?.objectValue
    )

    let provider = try XCTUnwrap(properties["provider_id"]?.objectValue)
    XCTAssertEqual(
      provider["type"]?.arrayValue,
      [.string("string"), .string("null")]
    )
    XCTAssertTrue(
      provider["description"]?.stringValue?.contains("opencode or antigravity") == true
    )

    let permission = try XCTUnwrap(properties["permission_mode"]?.objectValue)
    XCTAssertEqual(
      permission["enum"]?.arrayValue,
      [.string("read-only"), .string("workspace-write"), .null]
    )
    XCTAssertTrue(
      permission["description"]?.stringValue?.contains("Antigravity V1 accepts read-only only")
        == true
    )

    let network = try XCTUnwrap(properties["network_access"]?.objectValue)
    XCTAssertTrue(
      network["description"]?.stringValue?.contains("true is rejected") == true
    )

    let description = submit.description ?? ""
    for marker in [
      "provider_id=antigravity",
      "V1 accepts read-only tasks only",
      "official agy stream-json installation",
      "same project and installation",
    ] {
      XCTAssertTrue(description.contains(marker), "submit_task is missing: \(marker)")
    }

    let output = try XCTUnwrap(submit.outputSchema?.objectValue)
    let outputProperties = try XCTUnwrap(output["properties"]?.objectValue)
    XCTAssertNotNil(outputProperties["wait_policy"])
    let successBranch = try XCTUnwrap(output["oneOf"]?.arrayValue?.first?.objectValue)
    XCTAssertTrue(
      (successBranch["required"]?.arrayValue ?? []).contains(.string("wait_policy"))
    )
  }

  func testServerInstructionsExplainAntigravityRoutingAndSessionBinding() {
    let instructions = MCPServiceServerFactory.instructions(
      customInstructions: "",
      clientID: .chatGPT
    )

    for marker in [
      "explicitly set provider_id to antigravity",
      "V1 is read-only only",
      "never request workspace-write",
      "do not set network_access=true",
      "provider_session_id returned by get_task",
      "same project and installation",
    ] {
      XCTAssertTrue(instructions.contains(marker), "instructions are missing: \(marker)")
    }
  }

  func testAntigravityProviderAndSessionFieldsRoundTripThroughSubmissionContract() throws {
    let submission = MCPServiceTaskSubmission(
      projectID: "prj_antigravity",
      prompt: "Continue the review.",
      threadID: "agy-conversation-1",
      providerID: "antigravity",
      installationID: "ainst-antigravity-1",
      executionModel: "antigravity/model",
      executionEffort: "medium",
      modelOverride: true,
      permissionMode: "read-only",
      permissionModeOverride: true,
      networkAccess: false,
      clientRequestID: "agy-request-1"
    )

    let encoded = try JSONEncoder().encode(submission)
    let decoded = try JSONDecoder().decode(MCPServiceTaskSubmission.self, from: encoded)
    XCTAssertEqual(decoded, submission)

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    XCTAssertEqual(object["provider_id"] as? String, "antigravity")
    XCTAssertEqual(object["installation_id"] as? String, "ainst-antigravity-1")
    XCTAssertEqual(object["thread_id"] as? String, "agy-conversation-1")
    XCTAssertEqual(object["permission_mode"] as? String, "read-only")
    XCTAssertEqual(object["network_access"] as? Bool, false)
  }
}
