import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import MCP
import XCTest

final class WorkbenchPermissionModeMCPTests: XCTestCase {
  func testChatGPTMCPReadOnlyDefaultDoesNotOverrideWorkbenchWrite() async throws {
    try await assertMCPDefaultReadOnlyDoesNotOverrideWorkbenchWrite(
      clientID: .chatGPT,
      requestID: "chatgpt-workbench-write-default"
    )
  }

  func testQwenMCPReadOnlyDefaultDoesNotOverrideWorkbenchWrite() async throws {
    try await assertMCPDefaultReadOnlyDoesNotOverrideWorkbenchWrite(
      clientID: .qwenStudio,
      requestID: "qwen-workbench-write-default"
    )
  }

  private func assertMCPDefaultReadOnlyDoesNotOverrideWorkbenchWrite(
    clientID: MCPClientID,
    requestID: String
  ) async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    try await application.serviceSetWorkbenchPermissionMode(.workspaceWrite, deadline: deadline)

    let dispatcher = MCPServiceToolDispatcher(
      service: application,
      exposureMode: .full,
      clientID: clientID
    )
    let submitted = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.submitTask.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "prompt": .string("Use the Workbench write default."),
          "permission_mode": .string("read-only"),
          "client_request_id": .string(requestID),
        ]
      )
    )
    XCTAssertEqual(submitted.isError, false)

    let taskID = try XCTUnwrap(
      submitted.structuredContent?.objectValue?["task_id"]?.stringValue
    )
    let queried = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.getTask.rawValue,
        arguments: ["task_id": .string(taskID)]
      )
    )
    let task = try XCTUnwrap(
      queried.structuredContent?.objectValue?["task"]?.objectValue
    )
    XCTAssertEqual(task["source_client_id"], .string(clientID.rawValue))
    XCTAssertEqual(task["permission_mode"], .string("workspace-write"))
  }
}
