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
    XCTAssertEqual(
      model.projectDetails["project-1"]?.directWorkspace?.commands.map(\.name),
      ["Tests"]
    )
    XCTAssertEqual(model.tasks.map(\.taskID), ["task-1"])
    XCTAssertEqual(model.models.map(\.modelID), ["fixture-model"])
    XCTAssertEqual(model.modelPreferences?.executionEffort, "medium")
    XCTAssertEqual(model.customInstructions, "Fixture global instructions")
    XCTAssertEqual(model.agentProviders.map(\.providerID), ["opencode"])
    XCTAssertTrue(model.agentInstallations.isEmpty)
    XCTAssertEqual(factory.makeCount, 1)
  }

  func testAgentInstallationManagementUsesExplicitLocalClientOperations() async throws {
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

    model.registerAgentInstallation(
      providerID: "opencode",
      displayName: "OpenCode",
      executableURL: URL(fileURLWithPath: "/tmp/opencode-fixture")
    )
    try await waitUntil {
      model.agentInstallations.count == 1 && !model.isManagingAgents
    }
    let installationID = try XCTUnwrap(model.agentInstallations.first?.installationID)
    XCTAssertFalse(model.agentInstallations[0].isEnabled)
    XCTAssertEqual(model.agentInstallations[0].availability, "available")

    model.setAgentInstallationEnabled(installationID, enabled: true)
    try await waitUntil {
      model.agentInstallations.first?.isEnabled == true && !model.isManagingAgents
    }

    model.reprobeAgentInstallation(installationID, acceptReplacement: false)
    try await waitUntil {
      let actions = await client.agentActionsValue()
      return actions.count == 3 && !model.isManagingAgents
    }

    model.removeAgentInstallation(installationID)
    try await waitUntil {
      model.agentInstallations.isEmpty && !model.isManagingAgents
    }
    let actions = await client.agentActionsValue()
    XCTAssertEqual(
      actions,
      [
        "register:opencode",
        "enabled:agent-installation-1:true",
        "reprobe:agent-installation-1:false",
        "remove:agent-installation-1",
      ]
    )
  }

  func testGlobalCustomInstructionsReachServiceClient() async throws {
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

    model.saveCustomInstructions("GPT should summarize before plugin calls.")

    try await waitUntil {
      let snapshot = await client.mutationSnapshot()
      return snapshot.customInstructions == "GPT should summarize before plugin calls."
    }
    XCTAssertEqual(model.customInstructions, "GPT should summarize before plugin calls.")
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
      decision: "allow_for_session"
    )

    try await waitUntil {
      let snapshot = await client.mutationSnapshot()
      return snapshot.approvalDecisions == ["approval-1:allow_for_session"]
    }
  }

  func testDeleteConversationRoutesItsTaskToTheServiceClient() async throws {
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

    model.deleteTask("task-1")

    try await waitUntil {
      await client.deletedTaskIDsValue() == ["task-1"]
    }
  }

  func testSelectingWorkbenchProjectPersistsTheGPTDefault() async throws {
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

    model.selectProject("project-1")

    try await waitUntil {
      await client.workbenchProjectSelectionsValue() == ["project-1"]
    }
    XCTAssertEqual(model.selectedProjectID, "project-1")
    XCTAssertEqual(model.serviceStatus?.workbenchProjectID, "project-1")
  }

  func testSelectingWorkbenchProjectDoesNotPromoteThreadCatalogFailureToGlobalError()
    async throws
  {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient(failThreadList: true)
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    model.selectProject("project-1")

    try await waitUntil {
      let calls = await client.threadCallCounts()
      let selections = await client.workbenchProjectSelectionsValue()
      return calls.list == 2 && selections == ["project-1"]
    }
    XCTAssertEqual(model.selectedProjectID, "project-1")
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertTrue(model.threads.isEmpty)
    XCTAssertNil(model.errorMessage)
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

  func testOpenCodeTaskWithoutThreadIsSelectedAndStreamsSharedConversation() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let openCodeTask = MCPServiceTaskSnapshot(
      taskID: "opencode-task",
      projectID: "project-1",
      source: "mcp.client",
      sourceClientID: MCPClientID.chatGPT.rawValue,
      status: "running",
      providerID: "opencode",
      installationID: "installation-1",
      providerSessionID: "session-1",
      providerRunID: "run-1",
      currentStep: "Inspecting workspace",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-21T00:00:00Z"
    )
    await client.setTaskSnapshots([openCodeTask])
    await client.setSubscriptionPage(
      IPCTaskConversationPage(
        taskID: openCodeTask.taskID,
        messages: [
          IPCTaskConversationMessage(
            messageID: 1,
            key: "user:1",
            role: "user",
            content: "Inspect this project"
          ),
          IPCTaskConversationMessage(
            messageID: 2,
            key: "agent:1",
            role: "agent",
            content: "I found the project files."
          ),
        ]
      )
    )
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )

    await model.startAsync()

    try await waitUntil {
      model.selectedTaskID == openCodeTask.taskID
        && model.conversation?.taskID == openCodeTask.taskID
        && model.conversation?.entries.count == 2
    }
    let calls = await client.threadCallCounts()
    XCTAssertNil(model.selectedThreadID)
    XCTAssertNil(model.selectedThread)
    XCTAssertEqual(calls.read, 0)
    XCTAssertEqual(model.tasks.first?.providerDisplayName, "OpenCode")
    await model.shutdownUI()
  }

  func testOpeningCodexTaskStillReadsItsThreadCatalogEntry() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let codexTask = MCPServiceTaskSnapshot(
      taskID: "codex-task",
      projectID: "project-1",
      status: "completed",
      providerID: "codex",
      executionModel: "fixture-model",
      executionEffort: "medium",
      threadID: "thread-1",
      turnID: "turn-1",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-21T00:00:00Z"
    )
    await client.setTaskSnapshots([codexTask])
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )

    await model.startAsync()
    model.openTask(codexTask.taskID)

    try await waitUntil {
      let calls = await client.threadCallCounts()
      return model.selectedTaskID == codexTask.taskID && calls.read == 1
    }
    XCTAssertEqual(model.selectedThreadID, codexTask.threadID)
    XCTAssertEqual(model.selectedThread?.thread.threadID, codexTask.threadID)
    await model.shutdownUI()
  }

  func testLowFrequencyCatalogRefreshReloadsInstalledSkills() async throws {
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
    XCTAssertTrue(model.skills.isEmpty)

    await client.setSkills(["code review"])
    model.lastThreadCatalogRefreshAt = Date(timeIntervalSinceNow: -61)
    await model.refresh(silent: true, includeCatalog: false)

    XCTAssertEqual(model.skills.map(\.name), ["code review"])
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

  func testToastPostingAndManualClear() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil
    )

    XCTAssertNil(model.toast)
    model.postToast("测试提示", symbol: "info.circle", tone: .info)
    XCTAssertNotNil(model.toast)
    XCTAssertEqual(model.toast?.message, "测试提示")
    XCTAssertEqual(model.toast?.symbol, "info.circle")
    XCTAssertEqual(model.toast?.tone, .info)

    model.clearToast()
    XCTAssertNil(model.toast)
  }

  func testPolicyUpdatePostsFeedbackToast() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil
    )
    await model.startAsync()

    let draft = BridgeProjectPolicyDraft(
      readPermission: "allowed",
      writePermission: "allowed",
      networkPermission: "allowed"
    )
    model.updateProjectPolicy(projectID: "project-1", draft: draft)

    try await waitUntil {
      model.toast?.message == "项目权限配置已保存生效"
    }
    XCTAssertEqual(model.toast?.symbol, "checkmark.circle.fill")
    XCTAssertEqual(model.toast?.tone, .success)
  }

  func testWorkspaceDraftStateTracksModeCommandsAndBlacklistWithoutWhitespaceNoise() {
    let workspace = MCPDirectWorkspace(
      fileWritePermission: "allowed",
      commandMode: "full",
      commands: [
        MCPProjectCommand(
          commandID: "stored-id",
          name: "Tests",
          executable: "Scripts/with-xcode.sh",
          arguments: ["swift", "test"]
        )
      ],
      commandBlacklist: [
        MCPCommandBlacklistRule(ruleID: "stored-rule", executable: "rm", pattern: "-rf")
      ]
    )
    let loaded = ProjectWorkspaceDraftState(workspace: workspace)
    let equivalent = ProjectWorkspaceDraftState(
      commandMode: "full",
      commands: [
        BridgeWorkspaceCommandDraft(
          name: " Tests ",
          executable: " Scripts/with-xcode.sh ",
          arguments: " swift \n test ",
          workingDirectory: " "
        )
      ],
      commandBlacklist: [BridgeBlacklistDraft(executable: " rm ", pattern: " -rf ")]
    )
    let changedBlacklist = ProjectWorkspaceDraftState(
      commandMode: "full",
      commands: loaded.commands,
      commandBlacklist: [BridgeBlacklistDraft(executable: "git", pattern: "push")]
    )

    XCTAssertEqual(equivalent, loaded)
    XCTAssertNotEqual(changedBlacklist, loaded)
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
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
