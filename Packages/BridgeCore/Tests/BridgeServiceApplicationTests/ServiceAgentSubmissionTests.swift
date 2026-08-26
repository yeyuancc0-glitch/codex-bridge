import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import XCTest

/// End-to-end routing for the OpenCode read-only vertical slice: explicit
/// provider submissions persist agent identity, wait for the local start
/// approval, execute through the registered installation, and stream
/// normalized events into the shared task conversation.
final class ServiceAgentSubmissionTests: XCTestCase {
  // MARK: - Scripted provider

  private final class ScriptedAgentProvider: AgentProvider, @unchecked Sendable {
    let descriptor: AgentProviderDescriptor

    private struct Run {
      let continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
    }

    private let lock = NSLock()
    private var runs: [TaskID: Run] = [:]
    private(set) var startedRequests: [AgentExecutionRequest] = []
    private(set) var interruptCount = 0
    private(set) var shutdownCount = 0
    private(set) var approvalResponses: [(String, String)] = []
    private let returnedTaskID: TaskID?
    private let startError: AgentRuntimeError?
    private let supportsWorkspaceWrite: Bool
    private let supportedReasoningEfforts: [String]
    private let resolveApprovalError: AgentRuntimeError?
    private var modelProjectRoots: [String?] = []

    init(
      returnedTaskID: TaskID? = nil,
      startError: AgentRuntimeError? = nil,
      supportsWorkspaceWrite: Bool = false,
      supportedReasoningEfforts: [String] = [],
      resolveApprovalError: AgentRuntimeError? = nil
    ) throws {
      self.returnedTaskID = returnedTaskID
      self.startError = startError
      self.supportsWorkspaceWrite = supportsWorkspaceWrite
      self.supportedReasoningEfforts = supportedReasoningEfforts
      self.resolveApprovalError = resolveApprovalError
      descriptor = try AgentProviderDescriptor(
        providerID: .openCode,
        displayName: "OpenCode",
        adapterRevision: 1
      )
    }

    func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
      let capabilities: Set<AgentCapability> = [
        .sessionCreate, .interrupt, .textDelta, .reasoningDelta,
        .toolLifecycle, .plan, .usage, .workspaceRead, .profileSelection,
      ]

      let effectiveCapabilities =
        supportsWorkspaceWrite
        ? capabilities.union([.workspaceWriteInPlace])
        : capabilities
      guard
        let installation = try? AgentInstallation(
          id: request.installation.id,
          providerID: request.installation.providerID,
          executablePath: request.installation.executablePath,
          version: "1.18.22",
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
      return AgentProbeResult(
        installation: installation,
        available: true,
        capabilities: AgentCapabilitySnapshot(
          advertised: effectiveCapabilities,
          observed: effectiveCapabilities,
          enforced: effectiveCapabilities
        )
      )
    }

    func models(
      installation _: AgentInstallation,
      projectRoot: String?
    ) async throws -> [AgentModelDescriptor] {
      recordModelProjectRoot(projectRoot)
      return [
        try AgentModelDescriptor(
          id: "opencode/x-preview-f-free",
          displayName: "OpenCode Zen/Ox Alpha Free",
          supportedReasoningEfforts: supportedReasoningEfforts,
          defaultReasoningEffort: supportedReasoningEfforts.first
        )
      ]
    }

    func modelProjectRootsValue() -> [String?] {
      lock.lock()
      defer { lock.unlock() }
      return modelProjectRoots
    }

    private func recordModelProjectRoot(_ projectRoot: String?) {
      lock.lock()
      defer { lock.unlock() }
      modelProjectRoots.append(projectRoot)
    }

    func start(
      _ request: AgentExecutionRequest,
      installation: AgentInstallation
    ) async throws -> AgentExecutionHandle {
      if let startError { throw startError }
      let stream = register(request.taskID)
      recordStarted(request)
      let binding = try AgentBinding(
        providerID: .openCode,
        installationID: installation.id,
        providerSessionID: "sess-\(request.taskID.rawValue)",
        providerRunID: "run-\(request.taskID.rawValue)"
      )
      let control = AgentExecutionControl(
        interrupt: { [weak self] in
          self?.performInterrupt(request.taskID)
        },
        shutdown: { [weak self] in
          self?.performShutdown(request.taskID)
        },
        resolveApproval: { [weak self] approvalID, optionID in
          try self?.performResolve(approvalID: approvalID, optionID: optionID)
        }
      )
      return AgentExecutionHandle(
        taskID: returnedTaskID ?? request.taskID,
        binding: binding,
        capabilities: .empty,
        events: stream,
        control: control
      )
    }

    private func recordStarted(_ request: AgentExecutionRequest) {
      lock.lock()
      defer { lock.unlock() }
      startedRequests.append(request)
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

    func emit(_ envelope: AgentEventEnvelope) {
      lock.lock()
      let run = runs[envelope.taskID]
      lock.unlock()
      run?.continuation.yield(envelope)
    }

    func finish(taskID: TaskID) {
      lock.lock()
      let run = runs[taskID]
      lock.unlock()
      run?.continuation.finish()
    }

    private func performInterrupt(_ taskID: TaskID) {
      lock.lock()
      interruptCount += 1
      let run = runs[taskID]
      lock.unlock()
      let envelope = try? AgentEventEnvelope(
        taskID: taskID,
        providerID: .openCode,
        providerSessionID: "sess-\(taskID.rawValue)",
        providerRunID: "run-\(taskID.rawValue)",
        providerSequence: 9_001,
        event: .interrupted
      )
      if let envelope {
        run?.continuation.yield(envelope)
      }
      run?.continuation.finish()
    }

    private func performShutdown(_ taskID: TaskID) {
      lock.lock()
      shutdownCount += 1
      let run = runs[taskID]
      lock.unlock()
      run?.continuation.finish()
    }

    private func performResolve(approvalID: String, optionID: String) throws {
      lock.lock()
      defer { lock.unlock() }
      if let resolveApprovalError { throw resolveApprovalError }
      approvalResponses.append((approvalID, optionID))
    }
  }

  // MARK: - Tests

  func testRunnerRejectsMismatchedProviderHandleAndShutsItDown() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(returnedTaskID: TaskID(rawValue: "tsk-wrong"))
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let runner = ServiceAgentTaskRunner(
      registry: registry,
      providers: [.openCode: provider]
    )

    do {
      _ = try await runner.start(
        AgentTaskBrief(
          taskID: TaskID(rawValue: "tsk-expected"),
          providerID: .openCode,
          installationID: AgentInstallationID(rawValue: "ainst-route-opencode"),
          projectID: fixture.project.id,
          projectRoot: fixture.project.root.canonicalPath,
          prompt: "Inspect the repository.",
          networkAllowed: false
        ))
      XCTFail("Expected a mismatched handle to be rejected")
    } catch {
      XCTAssertEqual(error as? AgentRuntimeError, .malformedEvent("agent.handle.binding"))
    }
    XCTAssertEqual(provider.shutdownCount, 1)
  }

  func testRunnerMapsWorkspaceWriteToExclusiveCapabilityRequest() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(supportsWorkspaceWrite: true)
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let runner = ServiceAgentTaskRunner(
      registry: registry,
      providers: [.openCode: provider]
    )

    let handle = try await runner.start(
      AgentTaskBrief(
        taskID: TaskID(rawValue: "tsk-workspace-write"),
        providerID: .openCode,
        installationID: AgentInstallationID(rawValue: "ainst-route-opencode"),
        projectID: fixture.project.id,
        projectRoot: fixture.project.root.canonicalPath,
        prompt: "Update the project.",
        permissionMode: .workspaceWrite,
        profileID: AgentProfileID(rawValue: "controlled-readonly"),
        networkAllowed: false
      ))

    XCTAssertEqual(provider.startedRequests.count, 1)
    XCTAssertEqual(provider.startedRequests[0].mutationIntent, .workspaceWrite)
    XCTAssertEqual(provider.startedRequests[0].workspaceStrategy, .exclusiveProject)
    XCTAssertTrue(provider.startedRequests[0].requiredCapabilities.contains(.workspaceWriteInPlace))
    await handle.shutdown()
  }

  func testWorkspaceWriteAgentSubmissionUsesDatabaseWriteSlot() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(registry: registry, providers: [.openCode: provider])
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Update the project.",
        providerID: "opencode",
        permissionMode: "workspace-write",
        clientRequestID: "agent-workspace-write-slot"
      ),
      deadline: deadline
    )
    let taskID = TaskID(rawValue: receipt.taskID)
    let pending = try await fixture.tasks.task(id: taskID)
    let pendingTask = try XCTUnwrap(pending)
    XCTAssertEqual(pendingTask.permissionMode, .workspaceWrite)
    let activeWriteTask = try await fixture.tasks.activeWriteTask(projectID: fixture.project.id)
    XCTAssertEqual(activeWriteTask?.id, taskID)

    do {
      try await application.resolveTaskStartApproval(
        taskID: taskID,
        approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(for: taskID),
        approved: true,
        deadline: deadline
      )
      XCTFail("Expected workspace capability rejection")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .unavailable)
    }
    let failed = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .failed
    }
    XCTAssertEqual(failed.state.failureCode, "agent_start_failed")
    let releasedWriteTask = try await fixture.tasks.activeWriteTask(projectID: fixture.project.id)
    XCTAssertNil(releasedWriteTask)
  }

  func testOpenCodeSubmissionApprovesRunsAndStreamsIntoConversation() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))

    let models = try await application.serviceListAgentModels(
      installationID: AgentInstallationID(rawValue: "ainst-route-opencode"),
      deadline: deadline
    )
    XCTAssertEqual(models.map(\.modelID), ["opencode/x-preview-f-free"])
    XCTAssertEqual(models.first?.displayName, "OpenCode Zen/Ox Alpha Free")

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect repository layout and report findings.",
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-request-1"
      ),
      deadline: deadline
    )
    XCTAssertEqual(receipt.status, ServiceTaskStatus.awaitingLocalApproval.rawValue)
    XCTAssertFalse(receipt.reusedExistingTask)

    var stored = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    var task = try XCTUnwrap(stored)
    XCTAssertEqual(task.providerID, "opencode")
    XCTAssertEqual(task.installationID, "ainst-route-opencode")
    XCTAssertEqual(task.selectionMode, .explicit)
    XCTAssertEqual(task.executionModel, serviceDefaultProviderExecutionModel)
    XCTAssertEqual(task.permissionMode, .readOnly)

    // A read-only remote task keeps waiting across recovery and never holds
    // the project write slot.
    _ = try await fixture.tasks.recoverIncompleteTasks()
    stored = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    task = try XCTUnwrap(stored)
    XCTAssertEqual(task.state.status, .awaitingLocalApproval)
    let writeSlotTask = try await fixture.tasks.activeWriteTask(projectID: fixture.project.id)
    XCTAssertNil(writeSlotTask)

    // Idempotent replay of the identical submission reuses the same task.
    let replay = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect repository layout and report findings.",
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-request-1"
      ),
      deadline: deadline
    )
    XCTAssertTrue(replay.reusedExistingTask)
    XCTAssertEqual(replay.taskID, receipt.taskID)

    try await application.resolveTaskStartApproval(
      taskID: TaskID(rawValue: receipt.taskID),
      approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(
        for: TaskID(rawValue: receipt.taskID)),
      approved: true,
      deadline: deadline
    )

    let taskIDValue = TaskID(rawValue: receipt.taskID)
    let sessionID = "sess-\(receipt.taskID)"
    let runID = "run-\(receipt.taskID)"
    try emit(
      provider,
      taskID: taskIDValue,
      sequence: 1,
      event: .content(
        AgentContentUpdate(
          key: "msg-1", role: .assistant, kind: .message, mode: .delta,
          content: "Listing top-level entries.", isFinal: false, authoritative: false
        ))
    )
    try emit(
      provider,
      taskID: taskIDValue,
      sequence: 2,
      event: .content(
        AgentContentUpdate(
          key: "thought-1", role: .assistant, kind: .reasoning, mode: .delta,
          content: "Narrow scope to the root directory.", isFinal: false, authoritative: false
        ))
    )
    try emit(
      provider,
      taskID: taskIDValue,
      sequence: 3,
      event: .tool(
        AgentToolUpdate(
          key: "tool:call-1", name: "read", status: .completed, output: "12 entries"
        ))
    )
    try emit(
      provider,
      taskID: taskIDValue,
      sequence: 4,
      event: .tool(
        AgentToolUpdate(
          key: "tool:edit-1",
          name: "edit",
          kind: "edit",
          status: .completed,
          locations: [fixture.project.root.canonicalPath + "/Sources/Changed.swift"]
        ))
    )
    try emit(
      provider,
      taskID: taskIDValue,
      sequence: 5,
      event: .plan([AgentPlanEntry(content: "Summarize layout")])
    )
    try emit(
      provider,
      taskID: taskIDValue,
      sequence: 6,
      event: .content(
        AgentContentUpdate(
          key: "msg-1", role: .assistant, kind: .message, mode: .full,
          content: "The repository has 12 top-level entries.",
          isFinal: true, authoritative: true
        ))
    )
    try emit(
      provider,
      taskID: taskIDValue,
      sequence: 7,
      event: .completed(summary: "Layout report ready.", stopReason: nil)
    )
    provider.finish(taskID: taskIDValue)

    let completed = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "Layout report ready.")
    XCTAssertEqual(completed.state.changedFiles, ["Sources/Changed.swift"])
    XCTAssertEqual(completed.state.providerSessionID, sessionID)
    XCTAssertEqual(completed.state.providerRunID, runID)
    XCTAssertNil(completed.state.codexThreadID)
    XCTAssertEqual(provider.startedRequests.count, 1)
    XCTAssertEqual(provider.startedRequests[0].mutationIntent, .readOnly)
    XCTAssertEqual(
      provider.startedRequests[0].profileID,
      AgentProfileID(rawValue: "controlled-readonly")
    )
    XCTAssertEqual(provider.startedRequests[0].projectRoot, fixture.project.root.canonicalPath)

    let page = try await fixture.tasks.messages(taskID: taskIDValue, limit: 50)
    let keys = page.map(\.key)
    XCTAssertTrue(keys.contains("agent:msg-1"), "keys were \(keys)")
    XCTAssertTrue(keys.contains("reasoning:thought-1"))
    XCTAssertTrue(keys.contains("tool:call-1"))
    let finalMessage = try XCTUnwrap(page.first(where: { $0.key == "agent:msg-1" }))
    XCTAssertEqual(finalMessage.content, "The repository has 12 top-level entries.")
    let toolEntry = try XCTUnwrap(page.first(where: { $0.key == "tool:call-1" }))
    XCTAssertEqual(toolEntry.toolStatus, ExecutionToolCallStatus.completed.rawValue)

    let snapshot = try await application.serviceTask(
      taskID: receipt.taskID,
      recentEventLimit: 20,
      deadline: deadline
    )
    XCTAssertEqual(snapshot.providerID, "opencode")
    XCTAssertEqual(snapshot.installationID, "ainst-route-opencode")
    XCTAssertEqual(snapshot.providerSessionID, sessionID)
    XCTAssertEqual(snapshot.providerRunID, runID)
    XCTAssertNil(snapshot.threadID)
    XCTAssertNil(snapshot.turnID)
    XCTAssertEqual(snapshot.executionModel, serviceDefaultProviderExecutionModel)
    XCTAssertEqual(snapshot.permissionMode, "read-only")
    XCTAssertFalse(snapshot.networkAccess)
  }

  func testAgentModelCatalogUsesRequestedProjectRoot() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )

    _ = try await application.serviceListAgentModels(
      installationID: AgentInstallationID(rawValue: "ainst-route-opencode"),
      projectID: fixture.project.id.rawValue,
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )

    XCTAssertEqual(
      provider.modelProjectRootsValue(),
      [fixture.project.root.canonicalPath]
    )

    try await fixture.settings.set(
      fixture.project.id.rawValue,
      for: .workbenchProjectID
    )
    _ = try await application.serviceListAgentModels(
      installationID: AgentInstallationID(rawValue: "ainst-route-opencode"),
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    XCTAssertEqual(
      provider.modelProjectRootsValue(),
      [fixture.project.root.canonicalPath, fixture.project.root.canonicalPath]
    )
  }

  func testOpenCodeSubmissionUsesSavedBuildModeAndSupportedEffortByDefault() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    try await fixture.settings.set("opencode/x-preview-f-free", for: .openCodeDefaultModel)
    try await fixture.settings.setOpenCodeDefaultPermissionMode("build")
    try await fixture.settings.setOpenCodeDefaultEffort("high")
    let provider = try ScriptedAgentProvider(
      supportsWorkspaceWrite: true,
      supportedReasoningEfforts: ["low", "high"]
    )
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Use the saved OpenCode defaults.",
        providerID: "opencode",
        clientRequestID: "saved-opencode-defaults"
      ),
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)

    XCTAssertEqual(task.permissionMode, .workspaceWrite)
    XCTAssertEqual(task.executionModel, "opencode/x-preview-f-free")
    XCTAssertEqual(task.executionEffort, "high")
  }

  func testOpenCodeSubmissionIgnoresUnmarkedClientPermissionMode() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    try await fixture.settings.setOpenCodeDefaultPermissionMode("build")
    let provider = try ScriptedAgentProvider(supportsWorkspaceWrite: true)
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect the repository.",
        providerID: "opencode",
        permissionMode: "read-only",
        permissionModeOverride: false,
        clientRequestID: "unmarked-permission-mode"
      ),
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    XCTAssertEqual(storedTask?.permissionMode, .workspaceWrite)
  }

  func testOpenCodeSubmissionHonorsExplicitPermissionModeOverride() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    try await fixture.settings.setOpenCodeDefaultPermissionMode("build")
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Perform a read-only analysis without changing files.",
        providerID: "opencode",
        permissionMode: "read-only",
        permissionModeOverride: true,
        clientRequestID: "explicit-permission-mode"
      ),
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    XCTAssertEqual(storedTask?.permissionMode, .readOnly)
  }

  func testAgentApprovalUsesExistingLocalApprovalResolution() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(registry: registry, providers: [.openCode: provider])
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect the project.",
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-approval"
      ),
      deadline: deadline
    )
    let taskID = TaskID(rawValue: receipt.taskID)
    try await application.resolveTaskStartApproval(
      taskID: taskID,
      approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(for: taskID),
      approved: true,
      deadline: deadline
    )
    _ = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .running
    }
    let binding = try AgentBinding(
      providerID: .openCode,
      installationID: AgentInstallationID(rawValue: "ainst-route-opencode"),
      providerSessionID: "sess-\(receipt.taskID)",
      providerRunID: "run-\(receipt.taskID)"
    )
    let approval = try AgentApprovalRequest(
      approvalID: "approval-agent-1",
      taskID: taskID,
      binding: binding,
      providerItemID: "tool-call-approval",
      kind: .fileChange,
      title: "OpenCode wants to edit a file",
      relativePaths: ["Sources/Changed.swift"],
      options: [
        try AgentApprovalOption(id: "allow-once", name: "Allow once", kind: "allow_once"),
        try AgentApprovalOption(
          id: "allow-always", name: "Allow for session", kind: "allow_always"
        ),
        try AgentApprovalOption(id: "reject-once", name: "Deny", kind: "reject_once"),
      ]
    )
    try emit(provider, taskID: taskID, sequence: 1, event: .approvalRequested(approval))
    let pending = try await waitForApproval(application, approvalID: approval.approvalID)
    XCTAssertEqual(pending.availableDecisions, [.allow, .allowForSession, .deny])

    try await application.resolveCodexApproval(
      taskID: taskID,
      approvalID: approval.approvalID,
      decision: .allowForSession
    )
    XCTAssertEqual(provider.approvalResponses.map(\.0), [approval.approvalID])
    XCTAssertEqual(provider.approvalResponses.map(\.1), ["allow-always"])
    let resumed = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .running
    }
    XCTAssertEqual(resumed.state.status, .running)

    try emit(
      provider,
      taskID: taskID,
      sequence: 2,
      event: .completed(summary: "Done", stopReason: nil)
    )
    provider.finish(taskID: taskID)
    _ = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .completed
    }
  }

  func testAgentApprovalBindingMismatchFailsClosed() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(registry: registry, providers: [.openCode: provider])
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect.",
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-approval-mismatch"
      ),
      deadline: deadline
    )
    let taskID = TaskID(rawValue: receipt.taskID)
    try await application.resolveTaskStartApproval(
      taskID: taskID,
      approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(for: taskID),
      approved: true,
      deadline: deadline
    )
    _ = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .running
    }
    let binding = try AgentBinding(
      providerID: .openCode,
      installationID: AgentInstallationID(rawValue: "ainst-route-opencode"),
      providerSessionID: "sess-\(receipt.taskID)",
      providerRunID: "run-stale"
    )
    let approval = try AgentApprovalRequest(
      approvalID: "approval-agent-mismatch",
      taskID: taskID,
      binding: binding,
      providerItemID: "tool-call-mismatch",
      kind: .command,
      title: "Run a command",
      options: [
        try AgentApprovalOption(id: "allow-once", name: "Allow once", kind: "allow_once"),
        try AgentApprovalOption(id: "reject-once", name: "Deny", kind: "reject_once"),
      ]
    )
    try emit(provider, taskID: taskID, sequence: 1, event: .approvalRequested(approval))
    let failed = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .failed
    }
    XCTAssertEqual(failed.state.failureCode, "agent_execution_failed")
    XCTAssertTrue(provider.approvalResponses.isEmpty)
  }

  func testTaskSnapshotDecodesWithoutNewPermissionFields() throws {
    let data = Data(
      #"""
      {"task_id":"tsk-legacy","project_id":"prj-legacy","status":"completed","changed_files":[],"recent_events":[],"supervisor_status":"disabled","local_approval_required":false,"updated_at":"2026-08-26T00:00:00Z"}
      """#.utf8
    )
    let snapshot = try JSONDecoder().decode(MCPServiceTaskSnapshot.self, from: data)
    XCTAssertNil(snapshot.permissionMode)
    XCTAssertFalse(snapshot.networkAccess)
  }

  func testUnavailableModelKeepsItsOwnFailureCode() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(
      startError: .modelUnavailable("provider/missing-model")
    )
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect.",
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-model-unavailable"
      ),
      deadline: deadline
    )

    do {
      try await application.resolveTaskStartApproval(
        taskID: TaskID(rawValue: receipt.taskID),
        approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(
          for: TaskID(rawValue: receipt.taskID)
        ),
        approved: true,
        deadline: deadline
      )
      XCTFail("Expected the unavailable model to fail startup")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .unavailable)
    }
    let failed = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .failed
    }

    XCTAssertEqual(failed.state.failureCode, "agent_model_unavailable")
    XCTAssertTrue(failed.state.resultSummary?.contains("provider/missing-model") == true)
  }

  func testChangedPayloadConflictsOnSameRequestIdempotencyKey() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))

    _ = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Read the README.",
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-request-conflict"
      ),
      deadline: deadline
    )

    do {
      _ = try await application.serviceSubmitTask(
        MCPServiceTaskSubmission(
          projectID: fixture.project.id.rawValue,
          prompt: "Read a different file.",
          providerID: "opencode",
          permissionMode: "read-only",
          clientRequestID: "agent-request-conflict"
        ),
        deadline: deadline
      )
      XCTFail("Expected an idempotency conflict for a changed payload")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .idempotencyConflict)
    }

    do {
      _ = try await application.serviceSubmitTask(
        MCPServiceTaskSubmission(
          projectID: fixture.project.id.rawValue,
          prompt: "Read the README.",
          permissionMode: "read-only",
          clientRequestID: "agent-request-conflict"
        ),
        deadline: deadline
      )
      XCTFail("Expected an idempotency conflict when the provider differs")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .idempotencyConflict)
    }
  }

  func testOpenCodeSubmissionRejectsUnsupportedFieldsAndMissingInstallations() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: false)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )
    let projectID = fixture.project.id.rawValue

    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: projectID, prompt: "x", providerID: "claude-code"),
      expected: .contractRejected,
      reason: "unknown provider"
    )
    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: projectID, prompt: "x", providerID: "opencode",
        permissionMode: "workspace-write"),
      expected: .unavailable,
      reason: "write intent with no selectable installation"
    )
    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: projectID, prompt: "x", providerID: "opencode",
        networkAccess: true),
      expected: .unavailable,
      reason: "network request"
    )
    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: projectID, prompt: "x", providerID: "opencode",
        executionModel: "", modelOverride: true),
      expected: .contractRejected,
      reason: "empty model"
    )
    // Without modelOverride, the model field is ignored for compatibility,
    // so the next rejection is for the missing enabled installation, not the
    // model itself. Use a valid installation to verify the model is actually
    // accepted when override is present.
    do {
      let fixture2 = try await makeServiceApplicationFixture(self)
      let provider2 = try ScriptedAgentProvider()
      let registry2 = try await Self.makeRegistry(
        fixture: fixture2, provider: provider2, enabled: true)
      let app2 = makeServiceApplication(
        fixture: fixture2,
        catalogScript: serviceModelCatalogScript,
        agentRegistry: registry2,
        agentRunner: ServiceAgentTaskRunner(registry: registry2, providers: [.openCode: provider2])
      )
      let receipt = try await app2.serviceSubmitTask(
        MCPServiceTaskSubmission(
          projectID: fixture2.project.id.rawValue, prompt: "x",
          providerID: "opencode", executionModel: "openai/gpt-5.6-sol",
          modelOverride: true,
          clientRequestID: "model-override-ok"
        ),
        deadline: ContinuousClock.now.advanced(by: .seconds(10))
      )
      let stored = try await fixture2.tasks.task(id: TaskID(rawValue: receipt.taskID))
      XCTAssertEqual(stored?.executionModel, "openai/gpt-5.6-sol")
      XCTAssertEqual(stored?.executionEffort, serviceDefaultProviderExecutionEffort)
      try await assertRejected(
        app2,
        submission: MCPServiceTaskSubmission(
          projectID: fixture2.project.id.rawValue, prompt: "x",
          providerID: "opencode", executionEffort: "high", modelOverride: true),
        expected: .contractRejected,
        reason: "effort is unavailable for the selected ACP model"
      )
    } catch {
      XCTFail("Expected model override to be accepted, got \(error)")
    }
    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: projectID, prompt: "x", providerID: "opencode"),
      expected: .unavailable,
      reason: "no enabled installation"
    )
  }

  func testSteerIsRejectedAndInterruptRequiresMatchingAgentRun() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Watch the build directory.",
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-request-interrupt"
      ),
      deadline: deadline
    )
    try await application.resolveTaskStartApproval(
      taskID: TaskID(rawValue: receipt.taskID),
      approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(
        for: TaskID(rawValue: receipt.taskID)),
      approved: true,
      deadline: deadline
    )
    let runningRecord = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .running
    }
    let runID = try XCTUnwrap(runningRecord.state.providerRunID)

    do {
      _ = try await application.serviceSteerTask(
        taskID: receipt.taskID,
        expectedTurnID: runID,
        input: "focus elsewhere",
        deadline: deadline
      )
      XCTFail("Expected steer to be rejected for agent tasks")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .invalidTaskState)
    }

    do {
      _ = try await application.serviceInterruptTask(
        taskID: receipt.taskID,
        expectedTurnID: "not-the-run",
        deadline: deadline
      )
      XCTFail("Expected an interrupt with a stale run id to fail")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .turnMismatch)
    }

    _ = try await application.serviceInterruptTask(
      taskID: receipt.taskID,
      expectedTurnID: runID,
      deadline: deadline
    )
    let interrupted = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .interrupted
    }
    XCTAssertEqual(interrupted.state.status, .interrupted)
    XCTAssertEqual(provider.interruptCount, 1)
  }

  func testAgentStreamEndingWithoutTerminalEventFailsTask() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect the repository.",
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-stream-ended"
      ),
      deadline: deadline
    )
    try await application.resolveTaskStartApproval(
      taskID: TaskID(rawValue: receipt.taskID),
      approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(
        for: TaskID(rawValue: receipt.taskID)),
      approved: true,
      deadline: deadline
    )
    _ = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .running
    }

    provider.finish(taskID: TaskID(rawValue: receipt.taskID))

    let failed = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .failed
    }
    XCTAssertEqual(failed.state.failureCode, "agent_stream_ended")
    XCTAssertEqual(provider.interruptCount, 0)
    XCTAssertEqual(provider.shutdownCount, 1)
  }

  func testAgentSequenceRegressionFailsClosed() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider()
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.openCode: provider]
      )
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Inspect the repository.",
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-sequence-regression"
      ),
      deadline: deadline
    )
    try await application.resolveTaskStartApproval(
      taskID: TaskID(rawValue: receipt.taskID),
      approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(
        for: TaskID(rawValue: receipt.taskID)),
      approved: true,
      deadline: deadline
    )
    let taskID = TaskID(rawValue: receipt.taskID)
    _ = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .running
    }
    try emit(
      provider,
      taskID: taskID,
      sequence: 2,
      event: .content(
        AgentContentUpdate(
          key: "message", role: .assistant, kind: .message, mode: .delta,
          content: "first", isFinal: false, authoritative: false
        ))
    )
    try emit(
      provider,
      taskID: taskID,
      sequence: 1,
      event: .content(
        AgentContentUpdate(
          key: "message", role: .assistant, kind: .message, mode: .delta,
          content: "stale", isFinal: false, authoritative: false
        ))
    )

    let failed = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .failed
    }
    XCTAssertEqual(failed.state.failureCode, "agent_execution_failed")
    XCTAssertEqual(provider.shutdownCount, 1)
  }

  func testLegacyCodexStoreRoundTripKeepsProviderDefaults() async throws {
    let store = try SimpleServiceStore.inMemory()
    let projects = ServiceProjectService(store: store)
    _ = try await projects.register(
      name: "Round Trip",
      rootURL: FileManager.default.temporaryDirectory,
      id: ProjectID(rawValue: "prj-round-trip")
    )
    let tasks = ServiceTaskManager(store: store)
    let submitted = try await tasks.submit(
      ServiceTaskRequest(
        projectID: ProjectID(rawValue: "prj-round-trip"),
        source: .chatGPT,
        prompt: "Codex legacy path",
        executionModel: "execution-model",
        executionEffort: "high",
        permissionMode: .readOnly
      )
    )
    XCTAssertEqual(submitted.task.providerID, serviceCodexProviderID)
    XCTAssertNil(submitted.task.installationID)
    XCTAssertEqual(submitted.task.selectionMode, .legacyCodex)
    let decoded = try await store.task(id: submitted.task.id)
    XCTAssertEqual(decoded?.providerID, serviceCodexProviderID)
    XCTAssertEqual(decoded?.selectionMode, .legacyCodex)
    XCTAssertNil(decoded?.state.providerSessionID)
  }

  // MARK: - Helpers

  private static func makeRegistry(
    fixture: ServiceApplicationFixture,
    provider: ScriptedAgentProvider,
    enabled: Bool
  ) async throws -> ServiceAgentRegistry {
    let executableURL = fixture.root.appending(path: "opencode-route-fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-route-opencode") }
    )
    _ = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode",
        executablePath: executableURL.path,
        trustProfile: .managed,
        securityProfileID: AgentProfileID(rawValue: "controlled-readonly"),
        enableOnSuccess: enabled,
        projectRoot: fixture.project.root.canonicalPath
      )
    )
    return registry
  }

  private func emit(
    _ provider: ScriptedAgentProvider,
    taskID: TaskID,
    sequence: Int64,
    event: @autoclosure () throws -> AgentEvent
  ) throws {
    try provider.emit(
      AgentEventEnvelope(
        taskID: taskID,
        providerID: .openCode,
        providerSessionID: "sess-\(taskID.rawValue)",
        providerRunID: "run-\(taskID.rawValue)",
        providerSequence: sequence,
        event: try event()
      )
    )
  }

  private func waitForTask(
    _ fixture: ServiceApplicationFixture,
    taskID: String,
    timeout: TimeInterval = 10,
    _ condition: @escaping (ServiceTaskRecord) -> Bool
  ) async throws -> ServiceTaskRecord {
    let id = TaskID(rawValue: taskID)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let task = try await fixture.tasks.task(id: id), condition(task) {
        return task
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for task \(taskID).")
    throw CancellationError()
  }

  private func waitForApproval(
    _ application: BridgeServiceApplication,
    approvalID: String,
    timeout: TimeInterval = 10
  ) async throws -> ExecutionApprovalRequest {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let approval = await application.pendingCodexApprovals().first(where: {
        $0.id == approvalID
      }) {
        return approval
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for approval \(approvalID).")
    throw CancellationError()
  }

  private func assertRejected(
    _ application: BridgeServiceApplication,
    submission: MCPServiceTaskSubmission,
    expected: BridgeMCPQueryError,
    reason: String
  ) async throws {
    do {
      _ = try await application.serviceSubmitTask(
        submission,
        deadline: ContinuousClock.now.advanced(by: .seconds(10))
      )
      XCTFail("Expected rejection for \(reason)")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, expected, reason)
    }
  }
}
