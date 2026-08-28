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

  func testOpenCodeDynamicEffortDoesNotRequireStaticInstallationCapability() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let installation = IPCAgentInstallationSummary(
      installationID: "opencode-installation",
      providerID: "opencode",
      displayName: "OpenCode",
      executablePath: "/tmp/opencode",
      version: "1.18.22",
      protocolRevision: "1",
      adapterRevision: 1,
      trustProfile: "user_trusted",
      securityProfileID: "desktop-shared",
      isEnabled: true,
      availability: "available",
      effectiveCapabilities: ["workspace.read", "selection.model"],
      lastProbedAt: "2026-08-28T00:00:00Z",
      updatedAt: "2026-08-28T00:00:00Z"
    )
    let option = IPCAgentModelSummary(
      modelID: "openai/gpt-5.6-sol",
      displayName: "GPT-5.6 Sol",
      supportedReasoningEfforts: ["low", "high"],
      defaultReasoningEffort: "high"
    )
    await client.configureAgentInstallations([installation])
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
    await model.hydrateAgentModelState(installationID: installation.installationID)

    XCTAssertTrue(
      model.supportsAgentEffortSelection(
        providerID: "opencode",
        installationID: installation.installationID
      )
    )
  }

  func testOpenCodeProviderDefaultUsesCatalogModelThatAdvertisesDynamicEffort() async throws {
    let model = BridgeServiceAppModel(
      registration: TestServiceRegistration(status: .enabled),
      clientFactory: { TestBridgeServiceClient() },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    model.agentModelOptions = [
      IPCAgentModelSummary(modelID: "provider/first", displayName: "First"),
      IPCAgentModelSummary(
        modelID: "provider/current",
        displayName: "Current",
        supportedReasoningEfforts: ["low", "high"],
        defaultReasoningEffort: "high"
      ),
    ]

    XCTAssertEqual(model.agentSelectedModel(for: "opencode")?.modelID, "provider/current")
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

  func testHydrationReadsFreshCatalogBeforeEnrichingStoredDefault() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let current = IPCAgentModelSummary(
      modelID: "opencode/current",
      displayName: "Current"
    )
    await client.configureAgentModels([current])
    await client.configureAgentDefault("opencode/removed")
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    await model.hydrateAgentModelState(installationID: "opencode-installation")

    XCTAssertEqual(model.agentModelOptions, [current])
    let queries = await client.agentModelsQueriesValue()
    XCTAssertEqual(
      queries,
      [
        TestBridgeServiceClient.AgentModelsQuery(
          installationID: "opencode-installation",
          projectID: "project-1",
          modelID: nil,
          useStoredDefault: false
        )
      ]
    )
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

  func testAntigravityDefaultsHydrateAndPersistBuildPlanState() async throws {
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
      effectiveCapabilities: [
        "workspace.read", "workspace.write_in_place", "selection.model", "selection.effort",
      ],
      lastProbedAt: "2026-08-27T00:00:00Z",
      updatedAt: "2026-08-27T00:00:00Z"
    )
    let option = IPCAgentModelSummary(
      modelID: "antigravity/model",
      displayName: "Antigravity Model",
      supportedReasoningEfforts: ["low", "high"],
      defaultReasoningEffort: "high"
    )
    await client.configureAgentInstallations([installation])
    await client.configureAgentModels([option])
    _ = try await client.setAgentDefaults(
      providerID: "antigravity",
      model: option.modelID,
      permissionMode: "workspace-write",
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

    XCTAssertTrue(
      model.supportsAgentEffortSelection(
        providerID: "antigravity",
        installationID: installation.installationID
      )
    )

    await model.hydrateAgentModelState(
      installationID: installation.installationID,
      providerID: "antigravity"
    )
    let hydrated = model.agentModelDefault(for: "antigravity")
    XCTAssertEqual(hydrated.model, option.modelID)
    XCTAssertEqual(hydrated.permissionMode, "workspace-write")
    XCTAssertEqual(hydrated.effort, "high")

    model.saveAgentPermissionMode("plan", providerID: "antigravity")
    model.saveAgentEffort("low", providerID: "antigravity")
    try await waitUntil {
      let persisted = try? await client.agentModelDefault(providerID: "antigravity")
      return persisted?.permissionMode == "plan" && persisted?.effort == "low"
    }
    await model.shutdownUI()
  }

  func testConcurrentProviderHydrationKeepsCatalogsAndDefaultsIsolated() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let providers = [
      (providerID: "opencode", installationID: "installation-opencode", modelID: "opencode/model"),
      (
        providerID: "deepseek-harness",
        installationID: "installation-deepseek",
        modelID: "deepseek/model"
      ),
      (
        providerID: "antigravity",
        installationID: "installation-antigravity",
        modelID: "antigravity/model"
      ),
    ]
    await client.configureAgentModels(
      [IPCAgentModelSummary(modelID: providers[0].modelID, displayName: "OpenCode")],
      installationID: providers[0].installationID
    )
    await client.configureAgentModels(
      [IPCAgentModelSummary(modelID: providers[1].modelID, displayName: "DeepSeek")],
      installationID: providers[1].installationID
    )
    await client.configureAgentModels(
      [IPCAgentModelSummary(modelID: providers[2].modelID, displayName: "Antigravity")],
      installationID: providers[2].installationID
    )
    _ = try await client.setAgentDefaults(
      providerID: providers[0].providerID,
      model: providers[0].modelID,
      permissionMode: "build",
      effort: nil
    )
    _ = try await client.setAgentDefaults(
      providerID: providers[1].providerID,
      model: providers[1].modelID,
      permissionMode: "read-only",
      effort: "high"
    )
    _ = try await client.setAgentDefaults(
      providerID: providers[2].providerID,
      model: providers[2].modelID,
      permissionMode: "workspace-write",
      effort: "low"
    )
    await client.setAgentDefaultReadDelay(.milliseconds(10), providerID: providers[1].providerID)
    await client.setAgentDefaultReadDelay(.milliseconds(5), providerID: providers[2].providerID)
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    await withTaskGroup(of: Void.self) { group in
      for provider in providers {
        group.addTask {
          await model.hydrateAgentModelState(
            installationID: provider.installationID,
            providerID: provider.providerID
          )
        }
      }
    }

    for provider in providers {
      XCTAssertEqual(
        model.agentModelOptions(for: provider.providerID).map(\.modelID),
        [provider.modelID]
      )
      XCTAssertEqual(model.agentModelDefault(for: provider.providerID).model, provider.modelID)
    }
    XCTAssertEqual(model.agentModelOptions.map(\.modelID), [providers[0].modelID])
  }

  func testConcurrentProviderDefaultSavesDoNotCancelEachOther() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    _ = try await client.setAgentDefaults(
      providerID: "opencode",
      model: "opencode/model",
      permissionMode: "build",
      effort: "low"
    )
    _ = try await client.setAgentDefaults(
      providerID: "deepseek-harness",
      model: "deepseek/model",
      permissionMode: "read-only",
      effort: "medium"
    )
    _ = try await client.setAgentDefaults(
      providerID: "antigravity",
      model: "antigravity/model",
      permissionMode: "workspace-write",
      effort: "high"
    )
    await client.setAgentDefaultReadDelay(.milliseconds(25), providerID: "opencode")
    await client.setAgentDefaultReadDelay(.milliseconds(10), providerID: "deepseek-harness")
    await client.setAgentDefaultReadDelay(.milliseconds(5), providerID: "antigravity")
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    await model.hydrateAgentModelState(installationID: nil, providerID: "opencode")
    await model.hydrateAgentModelState(installationID: nil, providerID: "deepseek-harness")
    await model.hydrateAgentModelState(installationID: nil, providerID: "antigravity")

    model.saveAgentEffort("xhigh", providerID: "opencode")
    model.saveAgentEffort("high", providerID: "deepseek-harness")
    model.saveAgentEffort("low", providerID: "antigravity")

    try await waitUntil {
      let openCode = try? await client.agentModelDefault(providerID: "opencode")
      let deepSeek = try? await client.agentModelDefault(providerID: "deepseek-harness")
      let antigravity = try? await client.agentModelDefault(providerID: "antigravity")
      return openCode?.effort == "xhigh"
        && deepSeek?.effort == "high"
        && antigravity?.effort == "low"
        && model.agentModelDefault(for: "opencode").effort == "xhigh"
        && model.agentModelDefault(for: "deepseek-harness").effort == "high"
        && model.agentModelDefault(for: "antigravity").effort == "low"
    }
  }

  func testChangingInstallationClearsStaleCatalogUntilHydrationCompletes() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let first = IPCAgentModelSummary(modelID: "deepseek/first", displayName: "First")
    let second = IPCAgentModelSummary(modelID: "deepseek/second", displayName: "Second")
    await client.configureAgentModels([first], installationID: "deepseek-first")
    await client.configureAgentModels([second], installationID: "deepseek-second")
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    await model.hydrateAgentModelState(
      installationID: "deepseek-first",
      providerID: "deepseek-harness"
    )
    XCTAssertEqual(model.agentModelOptions(for: "deepseek-harness"), [first])
    await client.setAgentDefaultReadDelay(
      .milliseconds(100),
      providerID: "deepseek-harness"
    )

    let hydration = Task { @MainActor in
      await model.hydrateAgentModelState(
        installationID: "deepseek-second",
        providerID: "deepseek-harness"
      )
    }
    try await waitUntil {
      model.isRefreshingAgentModels(for: "deepseek-harness")
    }

    XCTAssertTrue(model.isRefreshingAgentModels(for: "deepseek-harness"))
    XCTAssertTrue(model.agentModelOptions(for: "deepseek-harness").isEmpty)

    await hydration.value
    XCTAssertFalse(model.isRefreshingAgentModels(for: "deepseek-harness"))
    XCTAssertEqual(model.agentModelOptions(for: "deepseek-harness"), [second])
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
      return !model.isRefreshingAgentModels(for: "deepseek-harness")
        && model.agentModelOptions(for: "deepseek-harness") == [option]
        && requestCount == requestCountBeforeRefresh + 1
    }
    XCTAssertEqual(model.agentModelDefault(for: "deepseek-harness").model, option.modelID)
    XCTAssertEqual(model.agentModelDefault(for: "deepseek-harness").effort, "high")
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

  func testTaskStartApprovalModeReachesServiceClient() async throws {
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
    XCTAssertEqual(model.taskStartApprovalMode, "require")

    model.setTaskStartApprovalMode("auto")

    try await waitUntil {
      let mode = try? await client.taskStartApprovalMode()
      return mode == "auto"
    }
    XCTAssertEqual(model.taskStartApprovalMode, "auto")
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

  func testApplicationTerminationUnregistersServiceWhenBackgroundPersistenceIsOff()
    async throws
  {
    let suiteName = "BridgeServiceAppModelTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1,
      userDefaults: defaults
    )
    XCTAssertTrue(model.keepServiceRunningAfterAppExit)
    model.keepServiceRunningAfterAppExit = false
    await model.startAsync()

    await model.shutdownForApplicationTermination()

    XCTAssertEqual(registration.unregisterCount, 1)
    XCTAssertEqual(registration.status, .notRegistered)
    let closeCount = await client.closeCount()
    XCTAssertEqual(closeCount, 1)
    let reloaded = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      userDefaults: defaults
    )
    XCTAssertFalse(reloaded.keepServiceRunningAfterAppExit)
  }

  func testApplicationTerminationLeavesServiceRegisteredWhenBackgroundPersistenceIsOn()
    async throws
  {
    let suiteName = "BridgeServiceAppModelTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1,
      userDefaults: defaults
    )
    await model.startAsync()

    await model.shutdownForApplicationTermination()

    XCTAssertEqual(registration.unregisterCount, 0)
    XCTAssertEqual(registration.status, .enabled)
    let closeCount = await client.closeCount()
    XCTAssertEqual(closeCount, 1)
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

  func testSilentRefreshDoesNotPublishVisibleRefreshState() async throws {
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
    let previousRefreshAt = model.lastRefreshAt
    await client.setStatusDelay(.milliseconds(100))

    let refresh = Task { @MainActor in
      await model.refresh(silent: true, includeCatalog: false)
    }
    try await Task.sleep(for: .milliseconds(20))

    XCTAssertTrue(model.refreshInProgress)
    XCTAssertFalse(model.isRefreshing)
    XCTAssertEqual(model.lastRefreshAt, previousRefreshAt)
    await refresh.value
    XCTAssertFalse(model.refreshInProgress)
    XCTAssertFalse(model.isRefreshing)
    XCTAssertEqual(model.lastRefreshAt, previousRefreshAt)
  }

  func testVisibleRefreshQueuedBehindSilentRefreshIsNotDropped() async throws {
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
    let previousRefreshAt = model.lastRefreshAt
    await client.setStatusDelay(.milliseconds(100))

    let silentRefresh = Task { @MainActor in
      await model.refresh(silent: true, includeCatalog: false)
    }
    try await Task.sleep(for: .milliseconds(20))
    await model.refresh(silent: false, includeCatalog: false)
    await silentRefresh.value

    XCTAssertFalse(model.refreshInProgress)
    XCTAssertFalse(model.isRefreshing)
    XCTAssertNotEqual(model.lastRefreshAt, previousRefreshAt)
  }

  func testIdlePollingBacksOffUntilLiveUpdatesAreNeeded() async throws {
    let model = BridgeServiceAppModel(
      registration: TestServiceRegistration(status: .enabled),
      clientFactory: { TestBridgeServiceClient() },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    let base = Duration.seconds(2)

    model.tasks = []
    model.approvals = []
    model.directApprovals = []
    XCTAssertEqual(model.nextPollingDelay(base: base), .seconds(10))

    model.approvals = [
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
    XCTAssertEqual(model.nextPollingDelay(base: base), base)

    model.approvals = []
    model.resolvingApprovalKeys = ["approval-1"]
    XCTAssertEqual(model.nextPollingDelay(base: base), base)
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

  func testRefreshKeepsUserSelectedAgentTaskWhileOtherTasksRemainActive() async throws {
    let registration = TestServiceRegistration(status: .enabled)
    let client = TestBridgeServiceClient()
    let first = MCPServiceTaskSnapshot(
      taskID: "agent-task-a",
      projectID: "project-1",
      status: "running",
      providerID: "opencode",
      providerRunID: "run-a",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-28T12:00:00Z"
    )
    let second = MCPServiceTaskSnapshot(
      taskID: "agent-task-b",
      projectID: "project-1",
      status: "running",
      providerID: "deepseek-harness",
      providerRunID: "run-b",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-28T11:59:00Z"
    )
    await client.setTaskSnapshots([first, second])
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    try await waitUntil { model.conversation?.taskID == first.taskID }

    model.openTask(second.taskID)
    try await waitUntil {
      model.selectedTaskID == second.taskID && model.conversation?.taskID == second.taskID
    }
    await client.setTaskSnapshots([second, first])
    await model.refresh(silent: true, includeCatalog: false)

    XCTAssertEqual(model.selectedTaskID, second.taskID)
    XCTAssertEqual(model.conversation?.taskID, second.taskID)
    let subscribeCalls = await client.subscribeCallsValue()
    XCTAssertEqual(subscribeCalls, 2)
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
    let earlierTask = MCPServiceTaskSnapshot(
      taskID: "earlier-codex-task",
      projectID: "project-1",
      status: "running",
      providerID: "codex",
      threadID: "thread-1",
      turnID: "earlier-turn",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-20T00:00:00Z"
    )
    await client.setTaskSnapshots([earlierTask, codexTask])
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
