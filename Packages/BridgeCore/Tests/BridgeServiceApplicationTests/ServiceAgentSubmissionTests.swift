import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeProjects
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import XCTest

/// End-to-end routing for registered agent providers: explicit submissions
/// persist provider identity, wait for local start approval, execute through
/// the registered installation, and stream normalized events into the shared
/// task conversation.
final class ServiceAgentSubmissionTests: XCTestCase {
  // MARK: - Scripted provider

  private final class ScriptedAgentProvider: AgentProvider, @unchecked Sendable {
    let descriptor: AgentProviderDescriptor
    let providerID: AgentProviderID
    let installationID: AgentInstallationID
    private let modelID: String

    private struct Run {
      let continuation: AsyncThrowingStream<AgentEventEnvelope, any Error>.Continuation
    }

    private let lock = NSLock()
    private var runs: [TaskID: Run] = [:]
    private(set) var startedRequests: [AgentExecutionRequest] = []
    private(set) var interruptCount = 0
    private(set) var steerInputs: [String] = []
    private(set) var shutdownCount = 0
    private(set) var approvalResponses: [(String, String)] = []
    private let returnedTaskID: TaskID?
    private let startError: AgentRuntimeError?
    private let supportsWorkspaceWrite: Bool
    private let baseCapabilities: Set<AgentCapability>?
    private let supportedReasoningEfforts: [String]
    private let resolveApprovalError: AgentRuntimeError?
    private var modelProjectRoots: [String?] = []
    private var modelSelections: [String?] = []

    init(
      providerID: AgentProviderID = .openCode,
      installationID: AgentInstallationID? = nil,
      returnedTaskID: TaskID? = nil,
      startError: AgentRuntimeError? = nil,
      supportsWorkspaceWrite: Bool = false,
      capabilities: Set<AgentCapability>? = nil,
      supportedReasoningEfforts: [String] = [],
      resolveApprovalError: AgentRuntimeError? = nil
    ) throws {
      self.providerID = providerID
      self.installationID =
        installationID ?? AgentInstallationID(rawValue: "ainst-route-\(providerID.rawValue)")
      modelID =
        providerID == .antigravity
        ? "antigravity/test-model"
        : "opencode/x-preview-f-free"
      self.returnedTaskID = returnedTaskID
      self.startError = startError
      self.supportsWorkspaceWrite = supportsWorkspaceWrite
      self.baseCapabilities = capabilities
      self.supportedReasoningEfforts = supportedReasoningEfforts
      self.resolveApprovalError = resolveApprovalError
      descriptor = try AgentProviderDescriptor(
        providerID: providerID,
        displayName: providerID == .antigravity ? "Antigravity" : "OpenCode",
        adapterRevision: 1
      )
    }

    func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
      let defaultCapabilities: Set<AgentCapability> = [
        .sessionCreate, .sessionContinue, .interrupt, .steer, .textDelta, .reasoningDelta,
        .toolLifecycle, .plan, .usage, .workspaceRead, .profileSelection,
        .modelSelection, .effortSelection,
      ]
      let capabilities = baseCapabilities ?? defaultCapabilities

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
      installation: AgentInstallation,
      projectRoot: String?
    ) async throws -> [AgentModelDescriptor] {
      try await models(
        installation: installation,
        projectRoot: projectRoot,
        selectedModelID: nil
      )
    }

    func models(
      installation _: AgentInstallation,
      projectRoot: String?,
      selectedModelID: String?
    ) async throws -> [AgentModelDescriptor] {
      recordModelProjectRoot(projectRoot)
      recordModelSelection(selectedModelID)
      if let selectedModelID, selectedModelID == "\(providerID.rawValue)/deleted" {
        throw AgentRuntimeError.modelUnavailable(selectedModelID)
      }
      return [
        try AgentModelDescriptor(
          id: modelID,
          displayName: providerID == .antigravity
            ? "Antigravity Test Model"
            : "OpenCode Zen/Ox Alpha Free",
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

    func modelSelectionsValue() -> [String?] {
      lock.lock()
      defer { lock.unlock() }
      return modelSelections
    }

    private func recordModelProjectRoot(_ projectRoot: String?) {
      lock.lock()
      defer { lock.unlock() }
      modelProjectRoots.append(projectRoot)
    }

    private func recordModelSelection(_ selectedModelID: String?) {
      lock.lock()
      defer { lock.unlock() }
      modelSelections.append(selectedModelID)
    }

    func start(
      _ request: AgentExecutionRequest,
      installation: AgentInstallation
    ) async throws -> AgentExecutionHandle {
      if let startError { throw startError }
      let stream = register(request.taskID)
      recordStarted(request)
      let binding = try AgentBinding(
        providerID: providerID,
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
        steer: { [weak self] text in
          self?.performSteer(text)
        },
        resolveApproval: { [weak self] approvalID, optionID in
          try self?.performResolve(approvalID: approvalID, optionID: optionID)
        }
      )
      return AgentExecutionHandle(
        taskID: returnedTaskID ?? request.taskID,
        binding: binding,
        capabilities: AgentCapabilitySnapshot(
          advertised: [.steer],
          observed: [.steer],
          enforced: [.steer]
        ),
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
        providerID: providerID,
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

    private func performSteer(_ text: String) {
      lock.lock()
      steerInputs.append(text)
      lock.unlock()
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

  func testOpenCodeSubmissionContinuesRequestedProviderSession() async throws {
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
    let firstTaskID = TaskID(rawValue: "tsk-session-first")
    _ = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .mcpClient,
        sourceClientID: MCPClientID.chatGPT.rawValue,
        clientRequestID: "agent-session-first",
        prompt: "Start the analysis.",
        providerID: AgentProviderID.openCode.rawValue,
        installationID: "ainst-route-opencode",
        selectionMode: .explicit,
        executionModel: serviceDefaultProviderExecutionModel,
        executionEffort: serviceDefaultProviderExecutionEffort,
        permissionMode: .readOnly
      ),
      taskID: firstTaskID
    )
    _ = try await fixture.tasks.approveAndBegin(taskID: firstTaskID)
    let sessionID = "session-existing"
    _ = try await fixture.tasks.markAgentExecutionStarted(
      taskID: firstTaskID,
      providerSessionID: sessionID,
      providerRunID: "run-first"
    )
    _ = try await fixture.tasks.complete(
      taskID: firstTaskID,
      resultSummary: "Initial analysis complete.",
      changedFiles: []
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Continue the prior analysis.",
        threadID: sessionID,
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-session-continue"
      ),
      deadline: deadline
    )

    let taskID = TaskID(rawValue: receipt.taskID)
    let taskRecord = try await fixture.tasks.task(id: taskID)
    let stored = try XCTUnwrap(taskRecord)
    XCTAssertEqual(stored.requestedThreadID, sessionID)

    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Continue concurrently.",
        threadID: sessionID,
        providerID: "opencode",
        permissionMode: "read-only",
        clientRequestID: "agent-session-concurrent"
      ),
      expected: .invalidTaskState,
      reason: "same provider session is already active"
    )

    try await application.resolveTaskStartApproval(
      taskID: taskID,
      approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(for: taskID),
      approved: true,
      deadline: deadline
    )

    XCTAssertEqual(provider.startedRequests.count, 1)
    XCTAssertEqual(provider.startedRequests[0].requestedSessionID, sessionID)
    XCTAssertTrue(provider.startedRequests[0].requiredCapabilities.contains(.sessionContinue))
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

  func testAgentModelRefreshCanIgnoreDeletedStoredDefault() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    try await fixture.settings.set("opencode/deleted", for: .openCodeDefaultModel)
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

    let models = try await application.serviceListAgentModels(
      installationID: AgentInstallationID(rawValue: "ainst-route-opencode"),
      projectID: fixture.project.id.rawValue,
      useStoredDefault: false,
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )

    XCTAssertEqual(models.map(\.modelID), ["opencode/x-preview-f-free"])
    let selections = provider.modelSelectionsValue()
    XCTAssertEqual(selections.count, 1)
    XCTAssertNil(selections[0])
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
          projectID: fixture2.project.id.rawValue,
          prompt: "x",
          threadID: "unknown-session",
          providerID: "opencode"
        ),
        expected: .taskNotFound,
        reason: "unknown provider session"
      )
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

  func testSteerIsAcceptedAndInterruptRequiresMatchingAgentRun() async throws {
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

    let steerReceipt = try await application.serviceSteerTask(
      taskID: receipt.taskID,
      expectedTurnID: runID,
      input: "focus elsewhere",
      deadline: deadline
    )
    XCTAssertTrue(steerReceipt.accepted)
    XCTAssertEqual(provider.steerInputs, ["focus elsewhere"])

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

  func testAntigravitySubmissionDefaultsToReadOnlySharedProject() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(providerID: .antigravity)
    let registry = try await Self.makeRegistry(
      fixture: fixture,
      provider: provider,
      enabled: true,
      securityProfileID: AgentProfileID(rawValue: "desktop-shared")
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.antigravity: provider]
      )
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Review the repository without changing files.",
        providerID: "antigravity",
        clientRequestID: "antigravity-read-only"
      ),
      deadline: deadline
    )
    XCTAssertEqual(receipt.status, ServiceTaskStatus.awaitingLocalApproval.rawValue)
    XCTAssertTrue(receipt.localApprovalRequired)

    let taskID = TaskID(rawValue: receipt.taskID)
    let pendingRecord = try await fixture.tasks.task(id: taskID)
    let pending = try XCTUnwrap(pendingRecord)
    XCTAssertEqual(pending.providerID, AgentProviderID.antigravity.rawValue)
    XCTAssertEqual(pending.installationID, "ainst-route-antigravity")
    XCTAssertEqual(pending.permissionMode, .readOnly)
    XCTAssertFalse(pending.networkAllowed)
    XCTAssertEqual(pending.selectionMode, .explicit)

    try await application.resolveTaskStartApproval(
      taskID: taskID,
      approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(for: taskID),
      approved: true,
      deadline: deadline
    )
    _ = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .running
    }

    let request = try XCTUnwrap(provider.startedRequests.first)
    XCTAssertEqual(request.mutationIntent, .readOnly)
    XCTAssertEqual(request.workspaceStrategy, .sharedProject)
    XCTAssertFalse(request.networkAccessRequested)
    XCTAssertTrue(request.requiredCapabilities.contains(.workspaceRead))
    XCTAssertFalse(request.requiredCapabilities.contains(.workspaceWriteInPlace))
    XCTAssertEqual(request.profileID, AgentProfileID(rawValue: "desktop-shared"))

    try emit(
      provider,
      taskID: taskID,
      sequence: 1,
      event: .completed(summary: "Review complete.", stopReason: nil)
    )
    provider.finish(taskID: taskID)
    let completed = try await waitForTask(fixture, taskID: receipt.taskID) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.providerSessionID, "sess-\(receipt.taskID)")
    XCTAssertEqual(completed.state.providerRunID, "run-\(receipt.taskID)")
    XCTAssertNil(completed.state.codexThreadID)
  }

  func testAntigravityRejectsWorkspaceWriteAndNetworkAdmission() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(providerID: .antigravity)
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.antigravity: provider]
      )
    )
    let projectID = fixture.project.id.rawValue

    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: projectID,
        prompt: "Modify the repository.",
        providerID: "antigravity",
        permissionMode: "workspace-write",
        permissionModeOverride: true,
        clientRequestID: "antigravity-write-rejected"
      ),
      expected: .contractRejected,
      reason: "Antigravity V1 is read-only"
    )
    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: projectID,
        prompt: "Use the network while reviewing.",
        providerID: "antigravity",
        permissionMode: "read-only",
        networkAccess: true,
        clientRequestID: "antigravity-network-rejected"
      ),
      expected: .unavailable,
      reason: "Antigravity network overrides are unavailable"
    )

    let projectTasks = try await fixture.tasks.tasks(projectID: fixture.project.id)
    XCTAssertTrue(projectTasks.isEmpty)
    XCTAssertTrue(provider.startedRequests.isEmpty)
  }

  func testAntigravityRejectsUnobservedModelCapabilityBeforeCreatingTask() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(
      providerID: .antigravity,
      capabilities: [.workspaceRead]
    )
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.antigravity: provider]
      )
    )

    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Use an unobserved model override.",
        providerID: "antigravity",
        executionModel: "antigravity/test-model",
        modelOverride: true,
        clientRequestID: "antigravity-model-unobserved"
      ),
      expected: .unavailable,
      reason: "Antigravity model selection requires installation-level observation"
    )

    let projectTasks = try await fixture.tasks.tasks(projectID: fixture.project.id)
    XCTAssertTrue(projectTasks.isEmpty)
    XCTAssertTrue(provider.startedRequests.isEmpty)
  }

  func testAntigravityModelCatalogRequiresEffectiveModelSelectionCapability() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(
      providerID: .antigravity,
      capabilities: [.workspaceRead]
    )
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry
    )

    let models = try await application.serviceListAgentModels(
      installationID: provider.installationID,
      projectID: fixture.project.id.rawValue,
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )

    XCTAssertTrue(models.isEmpty)
    XCTAssertTrue(provider.modelSelectionsValue().isEmpty)
  }

  func testAntigravityListAgentsProjectsReadOnlyEnforcementAndCapabilities() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(
      providerID: .antigravity,
      supportsWorkspaceWrite: true,
      capabilities: [.workspaceRead, .workspaceWriteInPlace]
    )
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let deniedRoot = fixture.root.appending(path: "read-only-project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: deniedRoot, withIntermediateDirectories: false)
    let deniedProject = try await fixture.projects.register(
      name: "Read-only Project",
      rootURL: deniedRoot,
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .denied,
        network: .denied
      ),
      id: ProjectID(rawValue: "prj-antigravity-read-only")
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry
    )

    let list = try await application.serviceAgents(
      projectID: deniedProject.id.rawValue,
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    let agent: MCPAgentSummary = try XCTUnwrap(list.agents.first)
    XCTAssertEqual(agent.providerID, AgentProviderID.antigravity.rawValue)
    XCTAssertEqual(agent.installationID, "ainst-route-antigravity")
    XCTAssertTrue(agent.taskSubmissionEnabled)
    XCTAssertEqual(agent.effectiveCapabilities, [AgentCapability.workspaceRead.rawValue])
    XCTAssertEqual(agent.workspaceEnforcement, "os_sandbox_read_only")
    XCTAssertEqual(agent.approvalEnforcement, "provider_soft_deny")
    XCTAssertEqual(agent.networkEnforcement, "provider_native")
  }

  func testAntigravitySessionContinuationRequiresExactProviderProjectAndInstallation()
    async throws
  {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(providerID: .antigravity)
    let installationID = AgentInstallationID(rawValue: "ainst-route-antigravity")
    let registry = try await Self.makeRegistry(
      fixture: fixture,
      provider: provider,
      enabled: true,
      installationID: installationID
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.antigravity: provider]
      )
    )
    let seedID = TaskID(rawValue: "tsk-antigravity-session-seed")
    _ = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .mcpClient,
        sourceClientID: MCPClientID.chatGPT.rawValue,
        clientRequestID: "antigravity-session-seed",
        prompt: "Seed the Antigravity conversation.",
        requestedThreadID: nil,
        providerID: AgentProviderID.antigravity.rawValue,
        installationID: installationID.rawValue,
        selectionMode: .explicit,
        executionModel: serviceDefaultProviderExecutionModel,
        executionEffort: serviceDefaultProviderExecutionEffort,
        permissionMode: .readOnly
      ),
      taskID: seedID
    )
    _ = try await fixture.tasks.approveAndBegin(taskID: seedID)
    _ = try await fixture.tasks.markAgentExecutionStarted(
      taskID: seedID,
      providerSessionID: "agy-session-1",
      providerRunID: "agy-run-1"
    )
    _ = try await fixture.tasks.complete(
      taskID: seedID,
      resultSummary: "Seed complete.",
      changedFiles: []
    )

    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let continued = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Continue the review.",
        threadID: "agy-session-1",
        providerID: AgentProviderID.antigravity.rawValue,
        installationID: installationID.rawValue,
        clientRequestID: "antigravity-session-continue"
      ),
      deadline: deadline
    )
    let continuedRecord = try await fixture.tasks.task(id: TaskID(rawValue: continued.taskID))
    let continuedTask = try XCTUnwrap(continuedRecord)
    XCTAssertEqual(continuedTask.requestedThreadID, "agy-session-1")
    XCTAssertEqual(continuedTask.providerID, AgentProviderID.antigravity.rawValue)
    XCTAssertEqual(continuedTask.installationID, installationID.rawValue)

    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Continue an unknown session.",
        threadID: "agy-missing-session",
        providerID: AgentProviderID.antigravity.rawValue,
        installationID: installationID.rawValue,
        clientRequestID: "antigravity-session-missing"
      ),
      expected: .taskNotFound,
      reason: "unknown Antigravity session"
    )

    let otherRoot = fixture.root.appending(path: "other-project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
    _ = try await fixture.projects.register(
      name: "Other Project",
      rootURL: otherRoot,
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .requiresLocalApproval,
        network: .denied
      ),
      id: ProjectID(rawValue: "prj-other")
    )
    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: "prj-other",
        prompt: "Continue from another project.",
        threadID: "agy-session-1",
        providerID: AgentProviderID.antigravity.rawValue,
        installationID: installationID.rawValue,
        clientRequestID: "antigravity-session-project-mismatch"
      ),
      expected: .taskNotFound,
      reason: "session is bound to its original project"
    )

    try await assertRejected(
      application,
      submission: MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Do not fall back to another provider.",
        threadID: "agy-session-1",
        providerID: AgentProviderID.openCode.rawValue,
        installationID: installationID.rawValue,
        clientRequestID: "antigravity-session-provider-mismatch"
      ),
      expected: .unavailable,
      reason: "session cannot cross providers"
    )
  }

  func testAntigravityRegistrationDoesNotReplaceLegacyCodexDefault() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try ScriptedAgentProvider(providerID: .antigravity)
    let registry = try await Self.makeRegistry(fixture: fixture, provider: provider, enabled: true)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry,
      agentRunner: ServiceAgentTaskRunner(
        registry: registry,
        providers: [.antigravity: provider]
      )
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Use the legacy default provider.",
        clientRequestID: "legacy-codex-with-antigravity"
      ),
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )
    let taskRecord = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(taskRecord)
    XCTAssertEqual(task.providerID, serviceCodexProviderID)
    XCTAssertNil(task.installationID)
    XCTAssertEqual(task.selectionMode, .legacyCodex)
    XCTAssertTrue(provider.startedRequests.isEmpty)
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
    enabled: Bool,
    providerID: AgentProviderID? = nil,
    installationID: AgentInstallationID? = nil,
    securityProfileID: AgentProfileID? = nil
  ) async throws -> ServiceAgentRegistry {
    let resolvedProviderID = providerID ?? provider.providerID
    let resolvedInstallationID =
      installationID ?? provider.installationID
    let executableURL = fixture.root.appending(
      path: "\(resolvedProviderID.rawValue)-route-fixture"
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [provider],
      makeInstallationID: { resolvedInstallationID }
    )
    _ = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: resolvedProviderID,
        displayName: resolvedProviderID == .antigravity ? "Antigravity" : "OpenCode",
        executablePath: executableURL.path,
        trustProfile: .managed,
        securityProfileID: securityProfileID
          ?? AgentProfileID(rawValue: "controlled-readonly"),
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
        providerID: provider.providerID,
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
