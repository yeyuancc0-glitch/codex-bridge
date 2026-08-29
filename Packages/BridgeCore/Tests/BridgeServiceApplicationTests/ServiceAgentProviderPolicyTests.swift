import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Darwin
import Foundation
import XCTest

final class ServiceAgentProviderPolicyTests: XCTestCase {
  func testAntigravityPolicyExposesSandboxedWriteContinuationAndQueuedSteerContract() {
    let policy = ServiceAgentProviderPolicyRegistry.antigravity

    XCTAssertEqual(policy.providerID, .antigravity)
    XCTAssertEqual(policy.displayName, "Antigravity")
    XCTAssertTrue(policy.supportsWorkspaceWrite)
    XCTAssertTrue(policy.supportsSessionContinuation)
    XCTAssertTrue(policy.supportsSteer)
    XCTAssertFalse(policy.supportsInteractiveApproval)
    XCTAssertTrue(policy.supportsModelSelection)
    XCTAssertTrue(policy.supportsEffortSelection)
    XCTAssertTrue(policy.supportsSkillSelection)
    XCTAssertFalse(policy.supportsSupervisor)
    XCTAssertTrue(policy.allowsNetworkAccess)
    XCTAssertEqual(policy.workspaceEnforcement, "bridge_workspace_sandbox")
    XCTAssertEqual(policy.approvalEnforcement, "provider_soft_deny")
    XCTAssertEqual(policy.networkEnforcement, "provider_native")

    let reported = Set(AgentCapability.allCases)
    XCTAssertEqual(
      policy.effectiveCapabilities(reported, projectAllowsWorkspaceWrite: true),
      [
        .sessionCreate, .sessionContinue, .interrupt, .steer, .toolLifecycle, .usage,
        .workspaceRead, .workspaceWriteInPlace, .modelSelection, .effortSelection, .shell,
        .webSearch, .webFetch, .mcpClient, .subagents, .childRuns,
      ]
    )
    XCTAssertEqual(
      policy.effectiveCapabilities(reported, projectAllowsWorkspaceWrite: false),
      [
        .sessionCreate, .sessionContinue, .interrupt, .steer, .toolLifecycle, .usage,
        .workspaceRead, .modelSelection, .effortSelection, .shell, .webSearch, .webFetch,
        .mcpClient, .subagents, .childRuns,
      ]
    )
  }

  func testDeepSeekPolicyExposesNativeWriteAndOneShotApprovalFreshSessionContract() {
    let policy = ServiceAgentProviderPolicyRegistry.deepSeekHarness

    XCTAssertEqual(policy.providerID, .deepSeekHarness)
    XCTAssertEqual(policy.displayName, "DeepSeek Harness")
    XCTAssertTrue(policy.requiresConfiguration)
    XCTAssertTrue(policy.supportsWorkspaceWrite)
    XCTAssertFalse(policy.supportsSessionContinuation)
    XCTAssertTrue(policy.supportsModelSelection)
    XCTAssertTrue(policy.supportsEffortSelection)
    XCTAssertTrue(policy.supportsSkillSelection)
    XCTAssertFalse(policy.supportsSupervisor)
    XCTAssertTrue(policy.supportsSteer)
    XCTAssertTrue(policy.supportsInteractiveApproval)
    XCTAssertTrue(policy.allowsNetworkAccess)
    XCTAssertEqual(policy.workspaceEnforcement, "provider_native")
    XCTAssertEqual(policy.approvalEnforcement, "local_app")
    XCTAssertEqual(policy.networkEnforcement, "provider_native")
    XCTAssertEqual(policy.registrationTrustProfile, .userTrusted)
    XCTAssertEqual(
      policy.registrationSecurityProfileID,
      ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID
    )

    let reported: Set<AgentCapability> = Set(AgentCapability.allCases)
    XCTAssertEqual(
      policy.effectiveCapabilities(reported, projectAllowsWorkspaceWrite: true),
      [
        .sessionCreate, .interrupt, .steer, .steerInterruptAndContinue, .textDelta,
        .toolLifecycle, .workspaceRead,
        .workspaceWriteInPlace, .oneShotApproval, .structuredApprovalPayload, .modelSelection,
        .effortSelection, .shell, .webSearch, .webFetch, .codeExecution, .subagents, .workflow,
        .skills,
      ]
    )
    XCTAssertEqual(
      policy.effectiveCapabilities(reported, projectAllowsWorkspaceWrite: false),
      [
        .sessionCreate, .interrupt, .steer, .steerInterruptAndContinue, .textDelta,
        .toolLifecycle, .workspaceRead,
        .oneShotApproval, .structuredApprovalPayload, .modelSelection, .effortSelection,
        .shell, .webSearch, .webFetch, .codeExecution, .subagents, .workflow, .skills,
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
      ServiceAgentProviderPolicyRegistry.displayName(for: .antigravity),
      "Antigravity"
    )
    XCTAssertEqual(
      ServiceAgentProviderPolicyRegistry.displayName(for: AgentProviderID(rawValue: "custom")),
      "custom"
    )
  }

  func testDeepSeekSubmissionUsesNativeWriteDefaultsAndProviderPresentation() async throws {
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
        AgentCapability.steer.rawValue,
        AgentCapability.textDelta.rawValue,
        AgentCapability.toolLifecycle.rawValue,
        AgentCapability.effortSelection.rawValue,
        AgentCapability.modelSelection.rawValue,
        AgentCapability.workspaceRead.rawValue,
        AgentCapability.workspaceWriteInPlace.rawValue,
        AgentCapability.oneShotApproval.rawValue,
        AgentCapability.structuredApprovalPayload.rawValue,
        AgentCapability.shell.rawValue,
        AgentCapability.webSearch.rawValue,
        AgentCapability.webFetch.rawValue,
        AgentCapability.codeExecution.rawValue,
        AgentCapability.subagents.rawValue,
        AgentCapability.workflow.rawValue,
        AgentCapability.skills.rawValue,
      ].sorted()
    )
    XCTAssertEqual(agent.workspaceEnforcement, "provider_native")
    XCTAssertEqual(agent.approvalEnforcement, "local_app")
    XCTAssertEqual(agent.networkEnforcement, "provider_native")

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
    XCTAssertEqual(task.permissionMode, .workspaceWrite)
    XCTAssertEqual(task.executionModel, "private-backend/model-v1")
    XCTAssertEqual(task.executionEffort, serviceDefaultProviderExecutionEffort)
    XCTAssertNil(task.requestedThreadID)
  }

  func testDeepSeekSkillInjectionUsesProviderNeutralPromptContract() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let skillDirectory = URL(fileURLWithPath: fixture.project.root.canonicalPath, isDirectory: true)
      .appending(path: "skills/review", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: skillDirectory,
      withIntermediateDirectories: true
    )
    try Data(
      "---\nname: review\ndescription: test\n---\n\nFollow the repository review checklist."
        .utf8
    ).write(to: skillDirectory.appending(path: "SKILL.md"), options: .atomic)

    let executableURL = fixture.root.appending(path: "deepseek-skill-fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    let provider = try DeepSeekPolicyFixtureProvider()
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-skill-deepseek") }
    )
    _ = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .deepSeekHarness,
        displayName: "DeepSeek Harness",
        executablePath: executableURL.path,
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
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.deepSeekHarness: provider]
      )
    )
    let taskID = try await assertAgentSkillInjectedIntoProviderPrompt(
      application: application,
      fixture: fixture,
      submission: MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect the repository.",
        skillName: "review",
        providerID: AgentProviderID.deepSeekHarness.rawValue,
        permissionMode: "read-only",
        clientRequestID: "deepseek-skill-injection"
      ),
      expectedPrompt:
        "Skill instructions for review:\n\n---\nname: review\ndescription: test\n---\n\nFollow the repository review checklist.\n\nUser task:\nInspect the repository.",
      deadline: ContinuousClock.now.advanced(by: .seconds(10)),
      providerPrompt: { provider.startedRequests.first?.prompt }
    )

    provider.complete(taskID: taskID)
    let completed = try await waitForTask(fixture, taskID: taskID) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "Skill run complete.")
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

    let networkReceipt = try await registeredApplication.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: projectID,
        prompt: "Use the Provider's native network tools.",
        providerID: AgentProviderID.deepSeekHarness.rawValue,
        networkAccess: true,
        clientRequestID: "deepseek-policy-network"
      ),
      deadline: ContinuousClock.now.advanced(by: .seconds(5))
    )
    XCTAssertEqual(networkReceipt.status, ServiceTaskStatus.awaitingLocalApproval.rawValue)
    let storedNetworkTask = try await fixture.tasks.task(
      id: TaskID(rawValue: networkReceipt.taskID))
    XCTAssertTrue(try XCTUnwrap(storedNetworkTask).networkAllowed)
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

  func testDeepSeekUsesOwnCatalogWithoutOpenCodeInstallationAndPersistsSelection() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let deepSeekProvider = try DeepSeekPolicyFixtureProvider()
    let deepSeekExecutable = fixture.root.appending(path: "deepseek-catalog-fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: deepSeekExecutable)
    XCTAssertEqual(chmod(deepSeekExecutable.path, 0o700), 0)
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [deepSeekProvider],
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
      modelID: "private-backend/model-v1",
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    XCTAssertEqual(models.map(\.modelID), ["private-backend/model-v1"])
    XCTAssertEqual(models[0].supportedReasoningEfforts, ["off", "low", "high", "max"])
    let openCodeInstallations = try await registry.installations(providerID: .openCode)
    XCTAssertTrue(openCodeInstallations.isEmpty)

    let receipt = try await application.serviceSubmitAgentTask(
      projectID: fixture.project.id.rawValue,
      providerID: AgentProviderID.deepSeekHarness.rawValue,
      installationID: "ainst-catalog-deepseek",
      model: "private-backend/model-v1",
      effort: "max",
      permissionMode: "read-only",
      prompt: "Inspect the workspace.",
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    let storedTask = try await fixture.store.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.executionModel, "private-backend/model-v1")
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

  private func waitForTask(
    _ fixture: ServiceApplicationFixture,
    taskID: TaskID,
    timeout: TimeInterval = 10,
    _ condition: @escaping (ServiceTaskRecord) -> Bool
  ) async throws -> ServiceTaskRecord {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let task = try await fixture.tasks.task(id: taskID), condition(task) {
        return task
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for task \(taskID.rawValue).")
    throw CancellationError()
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

private final class DeepSeekPolicyFixtureProvider: AgentProvider, @unchecked Sendable {
  private struct Run {
    let continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
  }

  let descriptor: AgentProviderDescriptor
  private let lock = NSLock()
  private var runs: [TaskID: Run] = [:]
  private(set) var startedRequests: [AgentExecutionRequest] = []

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
      .sessionCreate, .interrupt, .steer, .textDelta, .toolLifecycle, .workspaceRead,
      .workspaceWriteInPlace, .oneShotApproval, .structuredApprovalPayload, .modelSelection,
      .effortSelection, .shell, .webSearch, .webFetch, .codeExecution, .subagents, .workflow,
      .skills,
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
    if let selectedModelID, selectedModelID != "private-backend/model-v1" {
      throw AgentRuntimeError.modelUnavailable(selectedModelID)
    }
    return try [
      AgentModelDescriptor(
        id: "private-backend/model-v1",
        displayName: "Private Backend Model V1",
        supportedReasoningEfforts: ["off", "low", "high", "max"],
        defaultReasoningEffort: "high"
      )
    ]
  }

  func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    let stream = register(request.taskID)
    recordStarted(request)
    let binding = try AgentBinding(
      providerID: .deepSeekHarness,
      installationID: installation.id,
      providerSessionID: "sess-\(request.taskID.rawValue)",
      providerRunID: "run-\(request.taskID.rawValue)"
    )
    let capabilities: Set<AgentCapability> = [
      .sessionCreate, .interrupt, .steer, .textDelta, .toolLifecycle, .workspaceRead,
      .workspaceWriteInPlace, .oneShotApproval, .structuredApprovalPayload, .modelSelection,
      .effortSelection, .shell, .webSearch, .webFetch, .codeExecution, .subagents, .workflow,
      .skills,
    ]
    return AgentExecutionHandle(
      taskID: request.taskID,
      binding: binding,
      capabilities: AgentCapabilitySnapshot(
        advertised: capabilities,
        observed: capabilities,
        enforced: capabilities
      ),
      events: stream,
      control: AgentExecutionControl(
        interrupt: { [weak self] in self?.finish(taskID: request.taskID) },
        shutdown: { [weak self] in self?.finish(taskID: request.taskID) }
      )
    )
  }

  private func recordStarted(_ request: AgentExecutionRequest) {
    lock.lock()
    startedRequests.append(request)
    lock.unlock()
  }

  func complete(taskID: TaskID) {
    lock.lock()
    let run = runs[taskID]
    lock.unlock()
    let envelope = try? AgentEventEnvelope(
      taskID: taskID,
      providerID: .deepSeekHarness,
      providerSessionID: "sess-\(taskID.rawValue)",
      providerRunID: "run-\(taskID.rawValue)",
      providerSequence: 0,
      event: .completed(summary: "Skill run complete.", stopReason: nil)
    )
    if let envelope { run?.continuation.yield(envelope) }
    run?.continuation.finish()
  }

  private func register(_ taskID: TaskID)
    -> AsyncThrowingStream<AgentEventEnvelope, any Error>
  {
    lock.lock()
    defer { lock.unlock() }
    var continuationRef: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation!
    let stream = AsyncThrowingStream<AgentEventEnvelope, any Error>(
      bufferingPolicy: .unbounded
    ) { continuationRef = $0 }
    runs[taskID] = Run(continuation: continuationRef)
    return stream
  }

  private func finish(taskID: TaskID) {
    lock.lock()
    let run = runs[taskID]
    lock.unlock()
    run?.continuation.finish()
  }
}
