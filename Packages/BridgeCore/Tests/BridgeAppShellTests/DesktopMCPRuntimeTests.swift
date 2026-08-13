import BridgeAppModel
import BridgeMCP
import Foundation
import MCP
import XCTest

@testable import BridgeAppShell

final class DesktopMCPRuntimeTests: XCTestCase {
  func testRemoteSubmissionAdmissionTracksStrictTunnelHealth() async throws {
    let admission = DesktopMCPTaskAdmission()
    let source = MCPRuntimeTestRemoteAdmission()
    await admission.setRemoteCheck { await source.current() }

    await admission.configure(requiresHealthyRemote: false)
    try await admission.requireSubmissionAllowed()

    await admission.configure(requiresHealthyRemote: true)
    await assertThrowsErrorAsync(try await admission.requireSubmissionAllowed()) { error in
      XCTAssertEqual(error as? BridgeMCPQueryError, .unavailable)
    }

    await source.set(true)
    try await admission.requireSubmissionAllowed()

    await source.set(false)
    await assertThrowsErrorAsync(try await admission.requireSubmissionAllowed()) { error in
      XCTAssertEqual(error as? BridgeMCPQueryError, .unavailable)
    }
  }

  func testBackendBootstrapsAndPassesRealLoopbackMCPContract() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let system = await MCPRuntimeTestSystemService()
    let backend = LiveBridgeAppBackend(
      dataDirectoryURL: directory,
      system: system
    )

    let project = try await backend.onboardingProject()
    XCTAssertNil(project)
    let localURL = try await backend.configureOnboardingTransport(
      .local(pathSecret: String(repeating: "a", count: 43))
    )
    XCTAssertEqual(localURL.host, "127.0.0.1")
    try await backend.testOnboardingTransport()
    try await DesktopMCPRuntime.validate(
      transport: DesktopBoundedHTTPTransport(
        endpoint: localURL,
        authorization: "Bearer bounded-transport-test"
      )
    )

    await backend.shutdown()
    await assertThrowsErrorAsync(
      try await DesktopMCPRuntime.validate(
        transport: DesktopBoundedHTTPTransport(
          endpoint: localURL,
          authorization: "Bearer bounded-transport-test"
        )
      )
    )
  }

  func testRemoteSubmitFailsClosedWhileSupervisorIsolationIsUnavailable() async throws {
    let root = temporaryDirectory()
    let data = root.appendingPathComponent("Data", isDirectory: true)
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let system = await MCPRuntimeTestSystemService(selectedDirectory: project)
    let backend = LiveBridgeAppBackend(
      dataDirectoryURL: data,
      system: system
    )
    let registeredValue = try await backend.registerOnboardingProject()
    let registered = try XCTUnwrap(registeredValue)
    let localURL = try await backend.configureOnboardingTransport(
      .local(pathSecret: String(repeating: "s", count: 43))
    )
    let transport = HTTPClientTransport(
      endpoint: localURL,
      configuration: .ephemeral,
      streaming: false,
      sseInitializationTimeout: 1
    )
    let client = Client(
      name: "desktop-task-tools-test",
      version: "1",
      configuration: .strict
    )
    addTeardownBlock {
      await client.disconnect()
      await backend.shutdown()
    }
    _ = try await client.connect(transport: transport)

    let tools = try await client.listTools()
    XCTAssertEqual(
      tools.tools.map(\.name),
      MCPToolCatalog(includeTaskTools: true, includeProjectTools: true).definitions.map(\.name)
    )
    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: MCPTaskToolName.submitTask.rawValue,
      arguments: submissionArguments(projectID: registered.id.rawValue)
    )
    let result = try await context.value
    let structured = try XCTUnwrap(result.structuredContent?.objectValue)
    XCTAssertEqual(result.isError, true)
    XCTAssertEqual(structured["error"]?.objectValue?["code"], "unavailable")

    let updates = await backend.stateUpdates()
    var iterator = updates.makeAsyncIterator()
    let nextSnapshot = try await iterator.next()
    let snapshot = try XCTUnwrap(nextSnapshot)
    guard case .ready(let taskPage) = snapshot.presentation.tasks else {
      return XCTFail("Expected the durable task projection")
    }
    XCTAssertTrue(taskPage.tasks.isEmpty)
    XCTAssertNil(snapshot.pendingSheet)
  }

  private func submissionArguments(projectID: String) -> [String: Value] {
    [
      "idempotency_key": "desktop-task-tools:1",
      "project_id": .string(projectID),
      "thread": ["mode": "new", "thread_id": .null],
      "execution": [
        "model": "gpt-5.6-sol",
        "effort": "high",
        "permission_mode": "workspace-write",
        "network_access": false,
      ],
      "supervisor": [
        "enabled": true,
        "model": "gpt-5.6-luna",
        "effort": "medium",
      ],
      "contract": [
        "goal": "Verify the remote task admission boundary.",
        "background": "Use the registered project only.",
        "requirements": ["Persist the task before asking locally."],
        "acceptance_criteria": ["The local user can reject the task."],
        "non_goals": [],
        "constraints": ["Do not start before approval."],
        "allowed_paths": ["Sources"],
        "forbidden_paths": [".env"],
        "verification": [],
      ],
    ]
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-mcp-runtime-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}

private func assertThrowsErrorAsync(
  _ expression: @autoclosure () async throws -> some Sendable,
  _ errorHandler: (Error) -> Void = { _ in }
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw")
  } catch {
    errorHandler(error)
  }
}

@MainActor
private final class MCPRuntimeTestSystemService: DesktopSystemServing {
  private let selectedDirectory: URL?

  init(selectedDirectory: URL? = nil) {
    self.selectedDirectory = selectedDirectory
  }

  func selectProjectDirectory() async -> URL? { selectedDirectory }
  func open(_: URL) -> Bool { true }
  func copyToPasteboard(_: String) -> Bool { true }
  func showMainWindow() {}
  func terminateApplication() {}
}

private enum MCPRuntimeTestError: Error {
  case streamEnded
  case timeout
}

private actor MCPRuntimeTestRemoteAdmission {
  private var value = false

  func current() -> Bool { value }
  func set(_ value: Bool) { self.value = value }
}
