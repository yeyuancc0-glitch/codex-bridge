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
  }

  func testRemoteSubmitPublishesLocalConfirmationAndCanBeRejected() async throws {
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
    guard case .string(let taskID) = structured["task_id"] else {
      return XCTFail("Expected a task identifier")
    }
    XCTAssertEqual(structured["phase"], "awaitingLocalApproval")
    XCTAssertEqual(structured["local_approval_required"], true)

    let snapshot = try await pendingConfirmation(from: backend)
    guard case .taskConfirmation(let confirmation) = snapshot.pendingSheet else {
      return XCTFail("Expected a local task confirmation sheet")
    }
    XCTAssertEqual(confirmation.id, taskID)
    XCTAssertEqual(confirmation.projectName, "Project")
    XCTAssertFalse(confirmation.canRunReadOnly)

    do {
      try await backend.resolveLocalTask(
        requestID: taskID,
        decision: .start,
        model: "different-model",
        effort: "high"
      )
      XCTFail("Expected immutable execution settings to be enforced")
    } catch {
      XCTAssertEqual(error as? DesktopBackendError, .operationFailed)
    }

    try await backend.resolveLocalTask(
      requestID: taskID,
      decision: .reject,
      model: "gpt-5.6-sol",
      effort: "high"
    )
    let rejected = try await backendSnapshot(from: backend) { snapshot in
      guard case .ready(let page) = snapshot.presentation.tasks else { return false }
      return page.tasks.contains { $0.id == taskID && $0.status == .blocked }
        && snapshot.pendingSheet == nil
    }
    XCTAssertNil(rejected.pendingSheet)
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

  private func pendingConfirmation(
    from backend: LiveBridgeAppBackend
  ) async throws -> BridgeAppStateSnapshot {
    try await backendSnapshot(from: backend) { snapshot in
      if case .taskConfirmation = snapshot.pendingSheet { return true }
      return false
    }
  }

  private func backendSnapshot(
    from backend: LiveBridgeAppBackend,
    matching predicate: @escaping @Sendable (BridgeAppStateSnapshot) -> Bool
  ) async throws -> BridgeAppStateSnapshot {
    let updates = await backend.stateUpdates()
    return try await withThrowingTaskGroup(of: BridgeAppStateSnapshot.self) { group in
      group.addTask {
        for try await snapshot in updates where predicate(snapshot) { return snapshot }
        throw MCPRuntimeTestError.streamEnded
      }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw MCPRuntimeTestError.timeout
      }
      let snapshot = try await group.next()!
      group.cancelAll()
      return snapshot
    }
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
