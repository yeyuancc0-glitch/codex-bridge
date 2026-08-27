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
    XCTAssertFalse(policy.supportsModelSelection)
    XCTAssertFalse(policy.supportsEffortSelection)
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
      [.sessionCreate, .interrupt, .textDelta, .workspaceRead]
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
        "model override",
        MCPServiceTaskSubmission(
          projectID: projectID,
          prompt: "Choose a model.",
          providerID: AgentProviderID.deepSeekHarness.rawValue,
          executionModel: "deepseek/model",
          modelOverride: true,
          clientRequestID: "deepseek-policy-model"
        )
      ),
      (
        "effort override",
        MCPServiceTaskSubmission(
          projectID: projectID,
          prompt: "Choose effort.",
          providerID: AgentProviderID.deepSeekHarness.rawValue,
          executionEffort: "high",
          modelOverride: true,
          clientRequestID: "deepseek-policy-effort"
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
      .sessionCreate, .interrupt, .textDelta, .workspaceRead,
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
