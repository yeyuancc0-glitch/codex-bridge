import BridgeIPC
import BridgeMCP
import Foundation
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class BridgeServiceAppModelTests: XCTestCase {
  func testStartRegistersAndConnectsToBackgroundService() async throws {
    let registration = TestServiceRegistration(status: .notRegistered)
    let client = TestBridgeServiceClient()
    let factory = ClientFactoryRecorder(client: client)
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { factory.makeClient() },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )

    await model.startAsync()

    XCTAssertEqual(registration.registerCount, 1)
    XCTAssertEqual(model.registrationStatus, .enabled)
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.serviceStatus?.status.mcpState, "ready")
    XCTAssertEqual(model.projects.map(\.projectID), ["project-1"])
    XCTAssertEqual(model.tasks.map(\.taskID), ["task-1"])
    XCTAssertEqual(model.models.map(\.modelID), ["fixture-model"])
    XCTAssertEqual(factory.makeCount, 1)
  }

  func testShutdownClosesOnlyUIClientAndLeavesServiceRegistered() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    XCTAssertEqual(model.connectionState, .connected)

    await model.shutdownUI()

    let closeCount = await client.closeCount()
    XCTAssertEqual(closeCount, 1)
    XCTAssertEqual(registration.unregisterCount, 0)
    XCTAssertEqual(registration.status, .enabled)
    XCTAssertEqual(model.connectionState, .idle)
  }

  func testRequiresApprovalDoesNotCreateAnXPCClient() async {
    let registration = TestServiceRegistration(status: .requiresApproval)
    let client = TestBridgeServiceClient()
    let factory = ClientFactoryRecorder(client: client)
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { factory.makeClient() },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )

    await model.startAsync()

    XCTAssertEqual(model.connectionState, .requiresApproval)
    XCTAssertEqual(factory.makeCount, 0)
    XCTAssertEqual(registration.registerCount, 0)
  }

  func testLocalTaskAndCodexApprovalsReachTheServiceClient() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    model.approveTask("task-1")
    model.resolveApproval(
      IPCApprovalSummary(
        approvalID: "approval-1",
        taskID: "task-1",
        threadID: "thread-1",
        turnID: "turn-1",
        itemID: "item-1",
        kind: "command",
        title: "Run command",
        summary: "Run a bounded command."
      ),
      allow: true
    )

    try await waitUntil {
      let snapshot = await client.mutationSnapshot()
      return snapshot.approvedTaskIDs == ["task-1"]
        && snapshot.approvalDecisions == ["approval-1:allow"]
    }
  }

  func testDisableExplicitlyUnregistersService() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    await model.disableBackgroundService()

    XCTAssertEqual(registration.unregisterCount, 1)
    XCTAssertEqual(registration.status, .notRegistered)
    XCTAssertEqual(model.connectionState, .idle)
    XCTAssertNil(model.serviceStatus)
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition did not become true before the deadline.")
  }
}

@MainActor
private final class TestServiceRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus
  private(set) var registerCount = 0
  private(set) var unregisterCount = 0
  private(set) var openedSettingsCount = 0

  init(status: BridgeServiceRegistrationStatus) {
    self.status = status
  }

  func register() throws {
    registerCount += 1
    status = .enabled
  }

  func unregister() async throws {
    unregisterCount += 1
    status = .notRegistered
  }

  func openSystemSettings() {
    openedSettingsCount += 1
  }
}

@MainActor
private final class ClientFactoryRecorder {
  private let client: any BridgeServiceClientProtocol
  private(set) var makeCount = 0

  init(client: any BridgeServiceClientProtocol) {
    self.client = client
  }

  func makeClient() -> any BridgeServiceClientProtocol {
    makeCount += 1
    return client
  }
}

private actor TestBridgeServiceClient: BridgeServiceClientProtocol {
  struct MutationSnapshot: Sendable {
    let approvedTaskIDs: [String]
    let approvalDecisions: [String]
  }

  private var closes = 0
  private var approvedTaskIDs: [String] = []
  private var approvalDecisions: [String] = []
  private var exposureMode = MCPServiceExposureMode.readOnly

  func status() async throws -> IPCServiceStatusResponse {
    IPCServiceStatusResponse(
      status: BridgeStatusSnapshot(
        appVersion: "test",
        mcpState: "ready",
        tunnelState: "stopped",
        executionState: "ready",
        supervisorState: "ready",
        pendingApprovalCount: 1
      ),
      localMCPURL: "http://127.0.0.1:1234/mcp/test",
      exposureMode: exposureMode
    )
  }

  func projects() async throws -> [MCPProjectSummary] {
    [
      MCPProjectSummary(
        projectID: "project-1",
        name: "Fixture",
        capabilities: MCPProjectCapabilities(
          read: "allowed",
          write: "requiresLocalApproval",
          network: "denied"
        )
      )
    ]
  }

  func registerProject(_ request: IPCProjectRegistrationRequest) async throws -> MCPProjectDetail {
    MCPProjectDetail(
      projectID: "project-1",
      name: request.name,
      capabilities: MCPProjectCapabilities(
        read: request.readPermission,
        write: request.writePermission,
        network: request.networkPermission
      )
    )
  }

  func updateProjectPolicy(_ request: IPCProjectPolicyRequest) async throws -> MCPProjectDetail {
    MCPProjectDetail(
      projectID: request.projectID,
      name: "Fixture",
      capabilities: MCPProjectCapabilities(
        read: request.readPermission,
        write: request.writePermission,
        network: request.networkPermission
      )
    )
  }

  func removeProject(projectID _: String) async throws {}

  func models() async throws -> MCPModelList {
    MCPModelList(
      models: [
        MCPModelSummary(
          modelID: "fixture-model",
          displayName: "Fixture Model",
          isDefault: true,
          reasoningEfforts: ["medium"],
          defaultReasoningEffort: "medium"
        )
      ]
    )
  }

  func threads(_ request: IPCThreadListRequest) async throws -> MCPThreadPage {
    MCPThreadPage(
      threads: [
        MCPThreadSummary(
          threadID: "thread-1",
          title: "Fixture Thread",
          status: "idle"
        )
      ]
    )
  }

  func readThread(_ request: IPCThreadReadRequest) async throws -> MCPThreadReadPage {
    MCPThreadReadPage(
      thread: MCPThreadSummary(
        threadID: request.threadID,
        title: "Fixture Thread",
        status: "idle"
      ),
      detail: request.detail,
      entries: []
    )
  }

  func tasks(_ request: IPCTaskListRequest) async throws -> [MCPServiceTaskSnapshot] {
    _ = request
    return [taskSnapshot()]
  }

  func task(_ request: IPCTaskRequest) async throws -> MCPServiceTaskSnapshot {
    _ = request
    return taskSnapshot()
  }

  func approveTask(taskID: String) async throws {
    approvedTaskIDs.append(taskID)
  }

  func rejectTask(taskID _: String) async throws {}
  func stopTask(taskID _: String) async throws {}

  func approvals(taskID _: String?) async throws -> [IPCApprovalSummary] {
    [
      IPCApprovalSummary(
        approvalID: "approval-1",
        taskID: "task-1",
        threadID: "thread-1",
        turnID: "turn-1",
        itemID: "item-1",
        kind: "command",
        title: "Run command",
        summary: "Run a bounded command."
      )
    ]
  }

  func resolveApproval(_ request: IPCApprovalResolutionRequest) async throws {
    approvalDecisions.append("\(request.approvalID):\(request.decision)")
  }

  func setExposureMode(_ mode: MCPServiceExposureMode) async throws {
    exposureMode = mode
  }

  func close() async {
    closes += 1
  }

  func closeCount() -> Int {
    closes
  }

  func mutationSnapshot() -> MutationSnapshot {
    MutationSnapshot(
      approvedTaskIDs: approvedTaskIDs,
      approvalDecisions: approvalDecisions
    )
  }

  private func taskSnapshot() -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: "task-1",
      projectID: "project-1",
      status: "awaiting_local_approval",
      supervisorStatus: "starting",
      localApprovalRequired: true,
      updatedAt: "2026-08-17T00:00:00Z"
    )
  }
}
