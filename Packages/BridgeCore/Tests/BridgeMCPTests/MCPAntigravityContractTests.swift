import Foundation
import MCP
import XCTest

@testable import BridgeMCP

final class MCPAntigravityContractTests: XCTestCase {
  func testSubmitTaskSchemaPublishesAntigravityExecutionModesAndCapabilities() throws {
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
      provider["description"]?.stringValue?.contains("opencode, deepseek-harness, or antigravity")
        == true
    )

    let permission = try XCTUnwrap(properties["permission_mode"]?.objectValue)
    XCTAssertEqual(
      permission["enum"]?.arrayValue,
      [.string("read-only"), .string("workspace-write"), .null]
    )
    XCTAssertTrue(
      permission["description"]?.stringValue?.contains("Antigravity selects agy Plan") == true
    )
    XCTAssertTrue(
      permission["description"]?.stringValue?.contains("or Accept Edits")
        == true
    )
    XCTAssertTrue(
      properties["execution_model"]?.objectValue?["description"]?.stringValue?
        .contains("Antigravity") == true
    )
    XCTAssertTrue(
      properties["execution_effort"]?.objectValue?["description"]?.stringValue?
        .contains("Antigravity") == true
    )

    let network = try XCTUnwrap(properties["network_access"]?.objectValue)
    XCTAssertTrue(
      network["description"]?.stringValue?.contains("Provider-native policies") == true
    )
    XCTAssertTrue(
      network["description"]?.stringValue?.contains(
        "explicitly requires web search"
      ) == true
    )

    let description = submit.description ?? ""
    for marker in [
      "provider_id=antigravity",
      "official agy stream-json installation",
      "native plan/accept-edits modes",
      "Plan/read-only",
      "Accept Edits/workspace-write",
      "agy mode: plan",
      "agy mode: accept-edits",
      "session continuation",
      "steer_task queues follow-up",
      "native policy",
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
      "native plan/accept-edits modes",
      "Plan/read-only",
      "Accept Edits/workspace-write",
      "agy mode: plan",
      "agy mode: accept-edits",
      "queued steer",
      "native headless policy",
      "network_access records",
      "Set network_access=true whenever",
      "local access mode is full-access",
      "provider_session_id returned by get_task",
      "same project and installation",
    ] {
      XCTAssertTrue(instructions.contains(marker), "instructions are missing: \(marker)")
    }
    XCTAssertFalse(instructions.contains("read-only only"))
    XCTAssertFalse(instructions.contains("never request workspace-write"))
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
