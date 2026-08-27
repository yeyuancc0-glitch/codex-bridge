import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Darwin
import Foundation
import XCTest

final class ServiceAgentProviderPolicyTests: XCTestCase {
  func testDeepSeekPolicyExposesOnlyReadOnlyFreshSessionContract() {
    let policy = ServiceAgentProviderPolicyRegistry.deepSeekHarness

    XCTAssertEqual(policy.providerID, .deepSeekHarness)
    XCTAssertEqual(policy.displayName, "DeepSeek Harness")
    XCTAssertTrue(policy.requiresConfiguration)
    XCTAssertFalse(policy.supportsWorkspaceWrite)
    XCTAssertFalse(policy.supportsSessionContinuation)
    XCTAssertTrue(policy.supportsModelSelection)
    XCTAssertTrue(policy.supportsEffortSelection)
    XCTAssertEqual(policy.modelCatalogSourceProviderID, .openCode)
    XCTAssertEqual(policy.modelCatalogPrefix, "opencode-go/")
    XCTAssertEqual(policy.modelCatalogDefaultID, "opencode-go/deepseek-v4-pro")
    XCTAssertFalse(policy.supportsSkillSelection)
    XCTAssertFalse(policy.supportsSupervisor)
    XCTAssertFalse(policy.supportsSteer)
    XCTAssertFalse(policy.supportsInteractiveApproval)
    XCTAssertEqual(policy.workspaceEnforcement, "provider_native_read_only")
    XCTAssertEqual(policy.approvalEnforcement, "automatic_deny")
    XCTAssertEqual(policy.networkEnforcement, "unavailable")
    XCTAssertEqual(policy.registrationTrustProfile, .userTrusted)
    XCTAssertEqual(
      policy.registrationSecurityProfileID,
      ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID
    )

    let reported: Set<AgentCapability> = Set(AgentCapability.allCases)
    XCTAssertEqual(
      policy.effectiveCapabilities(reported, projectAllowsWorkspaceWrite: true),
      [
        .sessionCreate, .interrupt, .textDelta, .workspaceRead, .modelSelection,
        .effortSelection,
      ]
    )
  }

  func testProviderPolicyRegistryKeepsKnownDisplayNames() {
    XCTAssertEqual(
      ServiceAgentProviderPolicyRegistry.displayName(for: .codex),
      "Codex"
    )
    XCTAssertEqual(
      ServiceAgentProviderPolicyRegistry.displayName(for: .openCode),
      "OpenCode"
    )
    XCTAssertEqual(
      ServiceAgentProviderPolicyRegistry.displayName(for: .deepSeekHarness),
      "DeepSeek Harness"
    )
    XCTAssertEqual(
      ServiceAgentProviderPolicyRegistry.displayName(for: AgentProviderID(rawValue: "custom")),
      "custom"
    )
  }

  func testDeepSeekSubmissionUsesFixedReadOnlyDefaultsAndProviderPresentation() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let executableURL = fixture.root.appending(path: "deepseek-policy-fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    let provider = try DeepSeekPolicyFixtureProvider()
    let artifacts = try makeDeepSeekArtifactRequests(in: fixture.root)
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-policy-deepseek") }
    )
    let registered = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .deepSeekHarness,
        displayName: "DeepSeek Harness",
        executablePath: executableURL.path,
        trustProfile: .userTrusted,
        securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
        enableOnSuccess: true,
        projectRoot: fixture.project.root.canonicalPath,
        artifacts: artifacts
      )
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    let agents = try await application.serviceAgents(
      projectID: fixture.project.id.rawValue,
      deadline: deadline
    )
    let agent = try XCTUnwrap(agents.agents.first)
    XCTAssertEqual(agent.providerID, AgentProviderID.deepSeekHarness.rawValue)
    XCTAssertEqual(agent.installationID, registered.id.rawValue)
    XCTAssertTrue(agent.taskSubmissionEnabled)
    XCTAssertEqual(
      agent.effectiveCapabilities,
      [
        AgentCapability.interrupt.rawValue,
        AgentCapability.sessionCreate.rawValue,
        AgentCapability.textDelta.rawValue,
        AgentCapability.effortSelection.rawValue,
        AgentCapability.modelSelection.rawValue,
        AgentCapability.workspaceRead.rawValue,
      ].sorted()
    )
    XCTAssertEqual(agent.workspaceEnforcement, "provider_native_read_only")
    XCTAssertEqual(agent.approvalEnforcement, "automatic_deny")
    XCTAssertEqual(agent.networkEnforcement, "unavailable")

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect the repository.",
        providerID: AgentProviderID.deepSeekHarness.rawValue,
        clientRequestID: "deepseek-policy-defaults"
      ),
      deadline: deadline
    )
    let stored = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(stored)
    XCTAssertEqual(task.providerID, AgentProviderID.deepSeekHarness.rawValue)
    XCTAssertEqual(task.installationID, registered.id.rawValue)
    XCTAssertEqual(task.selectionMode, .explicit)
    XCTAssertEqual(task.permissionMode, .readOnly)
    XCTAssertEqual(task.executionModel, serviceDefaultProviderExecutionModel)
    XCTAssertEqual(task.executionEffort, serviceDefaultProviderExecutionEffort)
    XCTAssertNil(task.requestedThreadID)
  }

  func testDeepSeekSubmissionRejectsUnsupportedOverridesAndRemainsUnavailableUnregistered()
    async throws
  {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try DeepSeekPolicyFixtureProvider()
    let registry = ServiceAgentRegistry(store: fixture.store, providers: [provider])
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry
    )
    let projectID = fixture.project.id.rawValue

    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: projectID,
        prompt: "Inspect.",
        providerID: AgentProviderID.deepSeekHarness.rawValue
      ),
      expected: .unavailable
    )

    let executableURL = fixture.root.appending(path: "deepseek-policy-fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    let registeredRegistry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-policy-deepseek") }
    )
    let artifacts = try makeDeepSeekArtifactRequests(in: fixture.root)
    _ = try await registeredRegistry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .deepSeekHarness,
        displayName: "DeepSeek Harness",
        executablePath: executableURL.path,
        trustProfile: .userTrusted,
        securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
        enableOnSuccess: true,
        artifacts: artifacts
      )
    )
    let registeredApplication = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registeredRegistry
    )

    let unsupported: [(String, MCPServiceTaskSubmission)] = [
      (
        "workspace write",
        MCPServiceTaskSubmission(
          projectID: projectID,
          prompt: "Write.",
          providerID: AgentProviderID.deepSeekHarness.rawValue,
          permissionMode: "workspace-write",
          clientRequestID: "deepseek-policy-write"
        )
      ),
      (
        "session continuation",
        MCPServiceTaskSubmission(
          projectID: projectID,
          prompt: "Continue.",
          threadID: "old-session",
          providerID: AgentProviderID.deepSeekHarness.rawValue,
          clientRequestID: "deepseek-policy-session"
        )
      ),
      (
        "skill",
        MCPServiceTaskSubmission(
          projectID: projectID,
          prompt: "Use a skill.",
          skillName: "review",
          providerID: AgentProviderID.deepSeekHarness.rawValue,
          clientRequestID: "deepseek-policy-skill"
        )
      ),
      (
        "supervisor",
        MCPServiceTaskSubmission(
          projectID: projectID,
          prompt: "Use a supervisor.",
          providerID: AgentProviderID.deepSeekHarness.rawValue,
          supervisorModel: "reviewer",
          supervisorEffort: "medium",
          clientRequestID: "deepseek-policy-supervisor"
        )
      ),
      (
        "network",
        MCPServiceTaskSubmission(
          projectID: projectID,
          prompt: "Use network.",
          providerID: AgentProviderID.deepSeekHarness.rawValue,
          networkAccess: true,
          clientRequestID: "deepseek-policy-network"
        )
      ),
    ]
    for (name, submission) in unsupported {
      do {
        _ = try await registeredApplication.serviceSubmitTask(
          submission,
          deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        XCTFail("Expected \(name) to be rejected")
      } catch let error as BridgeMCPQueryError {
        XCTAssertTrue(
          error == .contractRejected || error == .unavailable,
          "Unexpected error for \(name): \(error)"
        )
      }
    }
  }

  func testDeepSeekManagedRegistrationRejectsNonReadOnlyTrustProfile() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let executableURL = fixture.root.appending(path: "deepseek-registration-profile")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [try DeepSeekPolicyFixtureProvider()]
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry
    )

    do {
      _ = try await application.serviceRegisterManagedAgent(
        ServiceAgentRegistrationRequest(
          providerID: .deepSeekHarness,
          displayName: "DeepSeek Harness",
          executablePath: executableURL.path,
          trustProfile: .managed,
          securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
          configurationPath: fixture.root.appending(path: "deepseek-launch_configuration")
            .path,
          artifacts: Array(try makeDeepSeekArtifactRequests(in: fixture.root).dropFirst())
        ),
        deadline: .now.advanced(by: .seconds(3))
      )
      XCTFail("Expected the registration profile to be rejected")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .contractRejected)
    }
  }

  func testDeepSeekUsesOpenCodeGoCatalogAndPersistsExplicitSelection() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let goProvider = try OpenCodeGoCatalogFixtureProvider()
    let deepSeekProvider = try DeepSeekPolicyFixtureProvider()
    let openCodeExecutable = fixture.root.appending(path: "opencode-go-catalog-fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: openCodeExecutable)
    XCTAssertEqual(chmod(openCodeExecutable.path, 0o700), 0)
    let openCodeRegistry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [goProvider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-catalog-opencode") }
    )
    _ = try await openCodeRegistry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode",
        executablePath: openCodeExecutable.path,
        trustProfile: .managed,
        securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
        enableOnSuccess: true,
        projectRoot: fixture.project.root.canonicalPath
      )
    )

    let deepSeekExecutable = fixture.root.appending(path: "deepseek-go-catalog-fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: deepSeekExecutable)
    XCTAssertEqual(chmod(deepSeekExecutable.path, 0o700), 0)
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [goProvider, deepSeekProvider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-catalog-deepseek") }
    )
    _ = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .deepSeekHarness,
        displayName: "DeepSeek Harness",
        executablePath: deepSeekExecutable.path,
        trustProfile: .userTrusted,
        securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
        enableOnSuccess: true,
        projectRoot: fixture.project.root.canonicalPath,
        artifacts: try makeDeepSeekArtifactRequests(in: fixture.root)
      )
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry
    )

    let models = try await application.serviceListAgentModels(
      installationID: AgentInstallationID(rawValue: "ainst-catalog-deepseek"),
      projectID: fixture.project.id.rawValue,
      modelID: "opencode-go/deepseek-v4-pro",
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    XCTAssertEqual(models.map(\.modelID), ["opencode-go/deepseek-v4-pro"])
    XCTAssertEqual(models[0].supportedReasoningEfforts, ["high", "max"])

    let receipt = try await application.serviceSubmitAgentTask(
      projectID: fixture.project.id.rawValue,
      providerID: AgentProviderID.deepSeekHarness.rawValue,
      installationID: "ainst-catalog-deepseek",
      model: "opencode-go/deepseek-v4-pro",
      effort: "max",
      permissionMode: "read-only",
      prompt: "Inspect the workspace.",
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    let storedTask = try await fixture.store.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.executionModel, "opencode-go/deepseek-v4-pro")
    XCTAssertEqual(task.executionEffort, "max")
    XCTAssertEqual(task.permissionMode, .readOnly)
  }

  private func assertRejected(
    _ application: BridgeServiceApplication,
    submission: MCPServiceTaskSubmission,
    expected: BridgeMCPQueryError
  ) async throws {
    do {
      _ = try await application.serviceSubmitTask(
        submission,
        deadline: ContinuousClock.now.advanced(by: .seconds(5))
      )
      XCTFail("Expected submission to be rejected")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, expected)
    }
  }

  private func makeDeepSeekArtifactRequests(in root: URL) throws
    -> [ServiceAgentInstallationArtifactRequest]
  {
    try AgentInstallationArtifactRole.allCases.map { role in
      let url = root.appending(path: "deepseek-\(role.rawValue)")
      try Data("fixture \(role.rawValue)\n".utf8).write(to: url)
      if role.requiresExecutable {
        XCTAssertEqual(chmod(url.path, 0o700), 0)
      }
      return try ServiceAgentInstallationArtifactRequest(role: role, path: url.path)
    }
  }
}

private struct DeepSeekPolicyFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor

  init() throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .deepSeekHarness,
      displayName: "DeepSeek Harness",
      adapterRevision: 1
    )
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard
      let installation = try? AgentInstallation(
        id: request.installation.id,
        providerID: .deepSeekHarness,
        executablePath: request.installation.executablePath,
        version: "0.1.1-rc.2",
        protocolRevision: "1"
      )
    else {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "The fixture installation is invalid."
      )
    }
    let capabilities: Set<AgentCapability> = [
      .sessionCreate, .interrupt, .textDelta, .workspaceRead, .modelSelection,
      .effortSelection,
    ]
    return AgentProbeResult(
      installation: installation,
      available: true,
      capabilities: AgentCapabilitySnapshot(
        advertised: capabilities,
        observed: capabilities,
        enforced: capabilities
      )
    )
  }

  func start(
    _: AgentExecutionRequest,
    installation _: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    throw AgentRuntimeError.processUnavailable
  }
}

private struct OpenCodeGoCatalogFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor

  init() throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .openCode,
      displayName: "OpenCode",
      adapterRevision: 1
    )
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard
      let installation = try? AgentInstallation(
        id: request.installation.id,
        providerID: .openCode,
        executablePath: request.installation.executablePath,
        version: "1.18.23",
        protocolRevision: "1"
      )
    else {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "The fixture installation is invalid."
      )
    }
    let capabilities: Set<AgentCapability> = [
      .sessionCreate, .interrupt, .textDelta, .workspaceRead, .modelSelection,
      .effortSelection,
    ]
    return AgentProbeResult(
      installation: installation,
      available: true,
      capabilities: AgentCapabilitySnapshot(
        advertised: capabilities,
        observed: capabilities,
        enforced: capabilities
      )
    )
  }

  func models(
    installation _: AgentInstallation,
    projectRoot _: String?,
    selectedModelID: String?
  ) async throws -> [AgentModelDescriptor] {
    if let selectedModelID, selectedModelID != "opencode-go/deepseek-v4-pro" {
      throw AgentRuntimeError.modelUnavailable(selectedModelID)
    }
    return try [
      AgentModelDescriptor(
        id: "opencode-go/deepseek-v4-pro",
        displayName: "OpenCode Go/DeepSeek V4 Pro",
        supportedReasoningEfforts: ["high", "max", "ultra"],
        defaultReasoningEffort: "high"
      ),
      AgentModelDescriptor(
        id: "other-provider/model",
        displayName: "Other Provider Model"
      ),
    ]
  }

  func start(
    _: AgentExecutionRequest,
    installation _: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    throw AgentRuntimeError.processUnavailable
  }
}
