import BridgeIPC
import BridgeMCP
import Foundation
import WebKit
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
    XCTAssertEqual(model.modelPreferences?.executionEffort, "medium")
    XCTAssertEqual(factory.makeCount, 1)
  }

  func testModelPreferencesReachServiceClient() async throws {
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

    model.setExecutionEffort("low")

    try await waitUntil {
      let snapshot = await client.mutationSnapshot()
      return snapshot.modelPreferences.executionEffort == "low"
    }
    XCTAssertEqual(model.modelPreferences?.executionEffort, "low")
  }

  func testModelCatalogFailureIsVisibleInsteadOfRemainingInLoadingState() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient(failModelCatalog: true)
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )

    await model.startAsync()

    XCTAssertTrue(model.models.isEmpty)
    XCTAssertNil(model.modelPreferences)
    XCTAssertNotNil(model.modelCatalogError)
  }

  func testSupervisorEnabledToggleReachesServiceClient() async throws {
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
    XCTAssertEqual(model.modelPreferences?.supervisorEnabled, true)

    model.setSupervisorEnabled(false)

    try await waitUntil {
      let snapshot = await client.mutationSnapshot()
      return snapshot.modelPreferences.supervisorEnabled == false
    }
    XCTAssertEqual(model.modelPreferences?.supervisorEnabled, false)
  }

  func testAccessModeAndFastModeReachServiceClient() async throws {
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
    XCTAssertEqual(model.modelPreferences?.accessMode, "request-approval")
    XCTAssertEqual(model.modelPreferences?.fastModeEnabled, false)

    model.setAccessMode("auto-review")
    model.setFastMode(true)

    try await waitUntil {
      let snapshot = await client.mutationSnapshot()
      return snapshot.modelPreferences.accessMode == "auto-review"
        && snapshot.modelPreferences.fastModeEnabled == true
    }
    XCTAssertEqual(model.modelPreferences?.accessMode, "auto-review")
    XCTAssertEqual(model.modelPreferences?.fastModeEnabled, true)
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

  func testCodexApprovalDecisionsReachTheServiceClient() async throws {
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
      return snapshot.approvalDecisions == ["approval-1:allow"]
    }
  }

  func testTunnelActionsRouteWithoutRetainingRuntimeKeyInViewState() async throws {
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

    let tunnelID = "tunnel_" + String(repeating: "a", count: 32)
    let runtimeKey = "runtime_key_test_only_123"
    model.configureTunnel(tunnelID: tunnelID, runtimeKey: runtimeKey)

    try await waitUntil {
      let snapshot = await client.mutationSnapshot()
      return snapshot.configuredTunnelIDs == [tunnelID]
    }
    XCTAssertEqual(model.serviceStatus?.tunnel.tunnelID, tunnelID)
    XCTAssertFalse(String(describing: model.serviceStatus).contains(runtimeKey))
    XCTAssertFalse((model.errorMessage ?? "").contains(runtimeKey))

    model.disconnectTunnel()
    try await waitUntil {
      let snapshot = await client.mutationSnapshot()
      return snapshot.tunnelDisconnectCount == 1
    }
    XCTAssertFalse(model.serviceStatus?.tunnel.enabled ?? true)

    model.clearTunnel()
    try await waitUntil {
      let snapshot = await client.mutationSnapshot()
      return snapshot.tunnelClearCount == 1
    }
    XCTAssertFalse(model.serviceStatus?.tunnel.configured ?? true)
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

  func testBackgroundPollingDoesNotReloadThreadCatalogOrOpenThreadBody() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: .milliseconds(20),
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )

    await model.startAsync()
    var calls = await client.threadCallCounts()
    XCTAssertEqual(calls.list, 1)
    XCTAssertEqual(calls.read, 0)
    XCTAssertEqual(model.threads.map(\.threadID), ["thread-1"])
    XCTAssertNil(model.selectedThread)

    try await Task.sleep(for: .milliseconds(90))
    calls = await client.threadCallCounts()
    XCTAssertEqual(calls.list, 1)
    XCTAssertEqual(calls.read, 0)
    await model.shutdownUI()
  }

  func testChatBrowserSleepsOnlyAfterLeavingWorkbenchForDelay() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1,
      chatBrowserSleepDelay: .milliseconds(50)
    )
    model.isChatBrowserEnabled = true
    model.selection = .workbench
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    model.chatWebView = webView

    model.selection = .projects
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertTrue(model.chatWebView === webView)

    model.selection = .workbench
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertTrue(model.chatWebView === webView)

    model.selection = .projects
    try await Task.sleep(for: .milliseconds(70))
    XCTAssertNil(model.chatWebView)
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
