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

  func testAgentInstallationRegistrationPreservesExternalConfigurationPath() async throws {
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
      providerID: "deepseek-harness",
      displayName: "DeepSeek Harness",
      executableURL: URL(fileURLWithPath: "/tmp/dsh-acp-demo"),
      configurationURL: URL(fileURLWithPath: "/tmp/deepseek-profile/cordis.yml")
    )
    try await waitUntil { !model.isManagingAgents }

    let registrationRequest = await client.registrationRequest()
    let request = try XCTUnwrap(registrationRequest)
    XCTAssertEqual(request.providerID, "deepseek-harness")
    XCTAssertEqual(request.configurationPath, "/tmp/deepseek-profile/cordis.yml")
    await model.shutdownUI()
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

  func testAgentTaskSubmissionCarriesNativePermissionMode() async throws {
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

    model.submitAgentTask(
      projectID: "project-1",
      providerID: "opencode",
      installationID: "agent-installation-1",
      model: "opencode/x-preview-f-free",
      permissionMode: "workspace-write",
      prompt: "Build the project."
    )

    try await waitUntil {
      await client.submittedAgentRequest() != nil && !model.isManagingAgents
    }
    let requestValue = await client.submittedAgentRequest()
    let request = try XCTUnwrap(requestValue)
    XCTAssertEqual(request.providerID, "opencode")
    XCTAssertEqual(request.permissionMode, "workspace-write")
    XCTAssertEqual(request.model, "opencode/x-preview-f-free")
  }

  func testAgentTaskSubmissionCarriesMCPSubmissionFields() async throws {
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

    model.submitAgentTask(
      projectID: "project-1",
      providerID: "opencode",
      installationID: "agent-installation-1",
      model: "opencode/model",
      effort: "high",
      permissionMode: "workspace-write",
      prompt: "Continue the task.",
      threadID: "session-1",
      skillName: "review",
      networkAccess: true,
      modelOverride: true,
      permissionModeOverride: true,
      acceptanceCriteria: ["Tests pass"],
      clientRequestID: "request-1"
    )

    try await waitUntil {
      await client.submittedAgentRequest() != nil && !model.isManagingAgents
    }
    let requestValue = await client.submittedAgentRequest()
    let request = try XCTUnwrap(requestValue)
    XCTAssertEqual(request.threadID, "session-1")
    XCTAssertEqual(request.skillName, "review")
    XCTAssertEqual(request.networkAccess, true)
    XCTAssertEqual(request.modelOverride, true)
    XCTAssertEqual(request.permissionModeOverride, true)
    XCTAssertEqual(request.acceptanceCriteria, ["Tests pass"])
    XCTAssertEqual(request.clientRequestID, "request-1")
  }

  func testAntigravityWithoutObservedSelectionCapabilitiesHidesCatalogAndStripsOverrides()
    async throws
  {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let installation = IPCAgentInstallationSummary(
      installationID: "antigravity-installation",
      providerID: "antigravity",
      displayName: "Antigravity",
      executablePath: "/tmp/agy",
      version: "1.1.21",
      protocolRevision: "stream-json-v1",
      adapterRevision: 1,
      trustProfile: "user_trusted",
      securityProfileID: "desktop-shared",
      isEnabled: true,
      availability: "available",
      effectiveCapabilities: ["workspace.read"],
      lastProbedAt: "2026-08-27T00:00:00Z",
      updatedAt: "2026-08-27T00:00:00Z"
    )
    let option = IPCAgentModelSummary(
      modelID: "antigravity/model",
      displayName: "Antigravity Model",
      supportedReasoningEfforts: ["high"],
      defaultReasoningEffort: "high"
    )
    await client.configureAgentInstallations([installation])
    await client.configureAgentModels([option])
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    XCTAssertFalse(
      model.supportsAgentModelSelection(
        providerID: "antigravity",
        installationID: installation.installationID
      )
    )
    XCTAssertFalse(
      model.supportsAgentEffortSelection(
        providerID: "antigravity",
        installationID: installation.installationID
      )
    )

    model.agentModelOptions = [option]
    model.submitAgentTask(
      projectID: "project-1",
      providerID: "antigravity",
      installationID: installation.installationID,
      model: option.modelID,
      effort: "high",
      permissionMode: "read-only",
      prompt: "Review the project."
    )

    try await waitUntil {
      await client.submittedAgentRequest() != nil && !model.isManagingAgents
    }
    let requestValue = await client.submittedAgentRequest()
    let request = try XCTUnwrap(requestValue)
    XCTAssertNil(request.model)
    XCTAssertNil(request.effort)
    XCTAssertEqual(request.permissionMode, "read-only")
  }

  func testHydratingAgentDefaultUsesServiceValueWithoutWritingBack() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    await client.configureAgentDefault("opencode/x-preview-f-free")
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    await model.hydrateAgentModelState(installationID: nil)

    XCTAssertEqual(model.openCodeDefaultModel, "opencode/x-preview-f-free")
    let writes = await client.agentDefaultWrites()
    XCTAssertTrue(writes.isEmpty)
  }

  func testDeepSeekDefaultsDoNotOverwriteOpenCodeDefaults() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    await client.configureOpenCodeDefault(
      model: "opencode-go/ox-alpha-free",
      permissionMode: "plan",
      effort: nil
    )
    _ = try await client.setAgentDefaults(
      providerID: "deepseek-harness",
      model: "private-backend/model-v1",
      permissionMode: nil,
      effort: "high"
    )
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    await model.hydrateAgentModelState(
      installationID: nil,
      providerID: "deepseek-harness"
    )
    XCTAssertEqual(
      model.agentModelDefault(for: "deepseek-harness").model,
      "private-backend/model-v1"
    )
    XCTAssertEqual(model.agentModelDefault(for: "deepseek-harness").effort, "high")
    XCTAssertNil(model.openCodeDefaultModel)
    XCTAssertNil(model.openCodeDefaultEffort)
    model.saveAgentEffort("max", providerID: "deepseek-harness")

    try await waitUntil {
      let persisted = try? await client.agentModelDefault(providerID: "deepseek-harness")
      return persisted?.effort == "max"
    }
    let openCode = try await client.agentModelDefault()
    XCTAssertEqual(openCode.model, "opencode-go/ox-alpha-free")
    XCTAssertEqual(openCode.permissionMode, "plan")
    XCTAssertNil(openCode.effort)
  }

  func testStaleAgentDefaultLoadCannotOverwriteNewSave() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    await client.configureAgentDefault("opencode/old")
    await client.setAgentDefaultReadDelay(.milliseconds(100))
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let load = Task { @MainActor in
      await model.hydrateAgentModelState(installationID: nil)
    }
    try await Task.sleep(for: .milliseconds(10))
    model.saveAgentModelDefault("opencode/new")
    await load.value

    try await waitUntil {
      let writes = await client.agentDefaultWrites()
      return model.openCodeDefaultModel == "opencode/new"
        && writes == ["opencode/new"]
    }
    XCTAssertEqual(model.openCodeDefaultModel, "opencode/new")
    let writes = await client.agentDefaultWrites()
    XCTAssertEqual(writes, ["opencode/new"])
  }

  func testAgentModelCatalogFailureKeepsExistingOptions() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let option = IPCAgentModelSummary(
      modelID: "opencode/x-preview-f-free",
      displayName: "OpenCode Free"
    )
    await client.configureAgentModels([option])
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    await model.hydrateAgentModelState(installationID: "agent-installation")
    XCTAssertEqual(model.agentModelOptions, [option])

    await client.setAgentModelsFailure(true)
    await model.hydrateAgentModelState(installationID: "agent-installation")

    XCTAssertEqual(model.agentModelOptions, [option])
  }

  func testRefreshingAgentModelsReplacesSnapshotAndClearsDeletedDefault() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let removed = IPCAgentModelSummary(
      modelID: "opencode/removed",
      displayName: "Removed"
    )
    let kept = IPCAgentModelSummary(
      modelID: "opencode/kept",
      displayName: "Kept"
    )
    let added = IPCAgentModelSummary(
      modelID: "opencode/added",
      displayName: "Added"
    )
    await client.configureAgentModels([removed, kept])
    await client.configureAgentDefault(removed.modelID)
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    await model.hydrateAgentModelState(installationID: "agent-installation")
    let requestCountBeforeRefresh = await client.agentModelRequestCountValue()

    await client.configureAgentModels([kept, added])
    model.refreshAgentModelCatalog(installationID: "agent-installation")

    try await waitUntil {
      let writes = await client.agentDefaultWrites()
      let requestCount = await client.agentModelRequestCountValue()
      return !model.isRefreshingAgentModels
        && model.agentModelOptions == [kept, added]
        && model.openCodeDefaultModel == nil
        && writes == [nil]
        && requestCount == requestCountBeforeRefresh + 1
    }
    XCTAssertEqual(
      model.toast?.message,
      "OpenCode 模型列表已刷新：新增 1 个，移除 1 个"
    )
  }

  func testRefreshingAgentModelsFailureKeepsSnapshotAndShowsInlineError() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let option = IPCAgentModelSummary(
      modelID: "opencode/current",
      displayName: "Current"
    )
    await client.configureAgentModels([option])
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    await model.hydrateAgentModelState(installationID: "agent-installation")
    await client.setAgentModelsFailure(true)

    model.refreshAgentModelCatalog(installationID: "agent-installation")

    try await waitUntil {
      !model.isRefreshingAgentModels && model.agentModelRefreshError != nil
    }
    XCTAssertEqual(model.agentModelOptions, [option])
  }

  func testRefreshingDeepSeekCatalogUsesOneLiveSnapshotForModelAndEffort() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let option = IPCAgentModelSummary(
      modelID: "gateway/model-v1",
      displayName: "Gateway Model",
      supportedReasoningEfforts: ["off", "high"],
      defaultReasoningEffort: "high"
    )
    await client.configureAgentModels([option])
    _ = try await client.setAgentDefaults(
      providerID: "deepseek-harness",
      model: option.modelID,
      permissionMode: nil,
      effort: "high"
    )
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    await model.hydrateAgentModelState(
      installationID: "agent-installation",
      providerID: "deepseek-harness"
    )
    let requestCountBeforeRefresh = await client.agentModelRequestCountValue()

    model.refreshAgentModelCatalog(
      installationID: "agent-installation",
      providerID: "deepseek-harness"
    )

    try await waitUntil {
      let requestCount = await client.agentModelRequestCountValue()
      return !model.isRefreshingAgentModels
        && model.agentModelOptions == [option]
        && requestCount == requestCountBeforeRefresh + 1
    }
    XCTAssertEqual(model.agentModelDefault(for: "deepseek-harness").model, option.modelID)
    XCTAssertEqual(model.agentModelDefault(for: "deepseek-harness").effort, "high")
  }

  func testProviderDefaultEffortFallsBackWhenModelHasNoVariants() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let option = IPCAgentModelSummary(
      modelID: "gateway/model-v1",
      displayName: "Gateway Model"
    )
    await client.configureAgentModels([option])
    _ = try await client.setAgentDefaults(
      providerID: "deepseek-harness",
      model: option.modelID,
      permissionMode: nil,
      effort: "high"
    )
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )

    await model.startAsync()
    await model.hydrateAgentModelState(
      installationID: "agent-installation",
      providerID: "deepseek-harness"
    )

    XCTAssertEqual(model.agentModelDefault(for: "deepseek-harness").effort, "high")
    XCTAssertNil(model.agentExecutionEffort(for: "deepseek-harness"))
  }

  func testRefreshingAgentModelsClearsRemovedEffortAndPreservesPersistedMode() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let option = IPCAgentModelSummary(
      modelID: "opencode/current",
      displayName: "Current",
      supportedReasoningEfforts: ["low"],
      defaultReasoningEffort: "low"
    )
    await client.configureAgentModels([option])
    await client.configureOpenCodeDefault(
      model: option.modelID,
      permissionMode: "plan",
      effort: "high"
    )
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    await model.hydrateAgentModelState(installationID: "agent-installation")

    model.refreshAgentModelCatalog(installationID: "agent-installation")

    try await waitUntil {
      !model.isRefreshingAgentModels
        && model.openCodeDefaultModel == option.modelID
        && model.openCodeDefaultPermissionMode == "plan"
        && model.openCodeDefaultEffort == nil
    }
    let writes = await client.agentDefaultWrites()
    XCTAssertEqual(writes, [option.modelID])
  }

  func testRefreshingAgentModelsInvalidatesInFlightHydrationDefaults() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let removed = IPCAgentModelSummary(
      modelID: "opencode/removed",
      displayName: "Removed"
    )
    let current = IPCAgentModelSummary(
      modelID: "opencode/current",
      displayName: "Current"
    )
    await client.configureAgentModels([current])
    await client.configureAgentDefault(removed.modelID)
    await client.setAgentDefaultReadDelay(.milliseconds(100))
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let hydration = Task { @MainActor in
      await model.hydrateAgentModelState(installationID: "agent-installation")
    }
    try await waitUntil {
      await client.agentModelDefaultReadCountValue() == 1
    }
    model.refreshAgentModelCatalog(installationID: "agent-installation")

    try await waitUntil {
      !model.isRefreshingAgentModels && model.agentModelOptions == [current]
    }
    await hydration.value

    XCTAssertEqual(model.agentModelOptions, [current])
    XCTAssertNil(model.openCodeDefaultModel)
    let writes = await client.agentDefaultWrites()
    XCTAssertEqual(writes, [nil])
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

  func testApprovalResolutionIsSingleFlightAndRemovesCardAfterServiceSuccess() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    await client.setApprovalResolutionDelay(.milliseconds(100))
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let approval = try XCTUnwrap(model.approvals.first)
    model.resolveApproval(approval, decision: "allow")
    XCTAssertTrue(model.isResolvingApproval(approval))

    model.resolveApproval(approval, decision: "allow")

    try await waitUntil {
      !model.isResolvingApproval(approval)
        && model.approvals.isEmpty
        && model.toast?.tone == .success
    }
    let snapshot = await client.mutationSnapshot()
    XCTAssertEqual(snapshot.approvalDecisions, ["approval-1:allow"])
    XCTAssertNil(model.errorMessage)

    model.applyApprovalSnapshot([approval])
    XCTAssertTrue(model.approvals.isEmpty)
  }

  func testApprovalReplyLossRecoversFromAuthoritativePendingSnapshot() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    await client.setFailApprovalReplyAfterResolution(true)
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let approval = try XCTUnwrap(model.approvals.first)
    model.resolveApproval(approval, decision: "allow")

    try await waitUntil {
      !model.isResolvingApproval(approval)
        && model.approvals.isEmpty
        && model.toast?.tone == .success
    }
    let snapshot = await client.mutationSnapshot()
    XCTAssertEqual(snapshot.approvalDecisions, ["approval-1:allow"])
    XCTAssertNil(model.errorMessage)
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

  func testTaskControlsUseProviderSpecificLiveBindingAndFailClosedWithoutOne() async throws {
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

    let codexTask = MCPServiceTaskSnapshot(
      taskID: "codex-running",
      projectID: "project-1",
      status: "running",
      providerID: "codex",
      turnID: "codex-turn-1",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-21T00:00:00Z"
    )
    let openCodeTask = MCPServiceTaskSnapshot(
      taskID: "opencode-running",
      projectID: "project-1",
      status: "running",
      providerID: "opencode",
      providerRunID: "opencode-run-1",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-21T00:00:00Z"
    )
    let terminalTask = MCPServiceTaskSnapshot(
      taskID: "terminal",
      projectID: "project-1",
      status: "completed",
      providerID: "codex",
      turnID: "old-turn",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-21T00:00:00Z"
    )
    let missingBindingTask = MCPServiceTaskSnapshot(
      taskID: "missing-binding",
      projectID: "project-1",
      status: "running",
      providerID: "opencode",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-21T00:00:00Z"
    )

    model.interruptTask(codexTask)
    model.steerTask(openCodeTask, input: "Continue with the tests.")
    model.interruptTask(terminalTask)
    model.steerTask(missingBindingTask, input: "This must not be sent.")

    try await waitUntil {
      await client.taskControlActionsValue().count == 2
    }
    let actions = await client.taskControlActionsValue()
    XCTAssertEqual(
      Set(actions),
      Set([
        "interrupt:codex-running:codex-turn-1",
        "steer:opencode-running:opencode-run-1:Continue with the tests.",
      ])
    )
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
