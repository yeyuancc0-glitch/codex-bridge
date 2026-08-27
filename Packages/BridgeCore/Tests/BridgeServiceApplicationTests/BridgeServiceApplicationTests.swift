import BridgeDirectCommand
import BridgeDomain
import BridgeMCP
import BridgeProjects
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import MCP
import XCTest

final class BridgeServiceApplicationTests: XCTestCase {
  func testGetTaskRedactsProviderSummaryBeforeMCPValidation() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let creation = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .mcpClient,
        sourceClientID: "chatgpt",
        prompt: "Inspect the project.",
        providerID: "opencode",
        installationID: "ainst-test",
        selectionMode: .explicit,
        executionModel: serviceDefaultProviderExecutionModel,
        executionEffort: serviceDefaultProviderExecutionEffort,
        supervisorModel: "supervisor-model",
        supervisorEffort: "medium",
        permissionMode: .readOnly
      )
    )
    let taskID = creation.task.id
    _ = try await fixture.tasks.approveAndBegin(taskID: taskID)
    _ = try await fixture.tasks.markAgentExecutionStarted(
      taskID: taskID,
      providerSessionID: "session-test",
      providerRunID: "run-test"
    )
    _ = try await fixture.tasks.updatePlan(
      taskID: taskID,
      currentStep: "进程/占用，tool()/plan"
    )
    _ = try await fixture.tasks.updateSupervisor(
      taskID: taskID,
      status: .running,
      summary: "分析进程/占用，tool()/plan"
    )
    let longResult =
      String(repeating: "说明 ", count: 4_650)
      + "OpenCode completed: 进程/协议 and tool()/plan details."
    for index in 0..<20 {
      _ = try await fixture.tasks.recordCommandCompletion(
        taskID: taskID,
        summary: String(repeating: "event \(index) tool()/path ", count: 80)
      )
    }
    let changedFiles = (0..<200).map {
      "Sources/Module\($0)/" + String(repeating: "component", count: 8) + ".swift"
    }
    _ = try await fixture.tasks.complete(
      taskID: taskID,
      resultSummary: longResult,
      changedFiles: changedFiles
    )

    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .full)
    let result = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.getTask.rawValue,
        arguments: ["task_id": .string(taskID.rawValue)]
      )
    )

    XCTAssertNotEqual(result.isError, true)
    let task = try XCTUnwrap(result.structuredContent?.objectValue?["task"]?.objectValue)
    XCTAssertEqual(task["status"], .string(ServiceTaskStatus.completed.rawValue))
    let currentStep = try XCTUnwrap(task["current_step"]?.stringValue)
    XCTAssertTrue(OutboundContentSecurity.isSafe(currentStep))
    XCTAssertTrue(currentStep.contains("[REDACTED]"))
    XCTAssertLessThanOrEqual(currentStep.utf8.count, 2 * 1_024)
    let supervisorSummary = try XCTUnwrap(task["supervisor_summary"]?.stringValue)
    XCTAssertTrue(OutboundContentSecurity.isSafe(supervisorSummary))
    XCTAssertTrue(supervisorSummary.contains("[REDACTED]"))
    XCTAssertLessThanOrEqual(supervisorSummary.utf8.count, 8 * 1_024)
    let summary = try XCTUnwrap(task["result_summary"]?.stringValue)
    XCTAssertTrue(OutboundContentSecurity.isSafe(summary))
    XCTAssertTrue(summary.contains("[REDACTED]"))
    XCTAssertLessThanOrEqual(summary.utf8.count, 32 * 1_024)
    let projectedFiles = try XCTUnwrap(task["changed_files"]?.arrayValue)
    XCTAssertLessThanOrEqual(
      projectedFiles.compactMap(\.stringValue).reduce(0) { $0 + $1.utf8.count },
      16 * 1_024
    )
    XCTAssertLessThanOrEqual(try XCTUnwrap(task["recent_events"]?.arrayValue).count, 6)
  }

  func testGetTaskProjectsRecentProviderActivityAndEffectiveUpdateTime() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let creation = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .mcpClient,
        sourceClientID: "chatgpt",
        prompt: "Inspect the project.",
        providerID: "opencode",
        installationID: "ainst-activity",
        selectionMode: .explicit,
        executionModel: serviceDefaultProviderExecutionModel,
        executionEffort: serviceDefaultProviderExecutionEffort,
        permissionMode: .readOnly
      )
    )
    let taskID = creation.task.id
    _ = try await fixture.tasks.approveAndBegin(taskID: taskID)
    let started = try await fixture.tasks.markAgentExecutionStarted(
      taskID: taskID,
      providerSessionID: "session-activity",
      providerRunID: "run-activity"
    )
    let reasoningDate = started.updatedAt.addingTimeInterval(10)
    let toolDate = started.updatedAt.addingTimeInterval(20)
    try await fixture.tasks.upsertTaskMessage(
      taskID: taskID,
      key: "reasoning:item-1",
      role: .agent,
      content: "Inspecting modules.",
      kind: .reasoning,
      createdAt: reasoningDate
    )
    try await fixture.tasks.upsertTaskMessage(
      taskID: taskID,
      key: "tool:item-2",
      role: .agent,
      content: "{}",
      kind: .toolCall,
      toolName: "read",
      toolStatus: "inProgress",
      createdAt: toolDate
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    let snapshot = try await application.serviceTask(
      taskID: taskID.rawValue,
      recentEventLimit: 20,
      deadline: deadline
    )

    XCTAssertEqual(snapshot.recentActivity.map(\.kind), ["reasoning", "tool_lifecycle"])
    XCTAssertTrue(snapshot.recentActivityAvailable)
    XCTAssertEqual(
      snapshot.recentActivity.map(\.summary),
      ["Inspecting modules.", "read (inProgress)"]
    )
    XCTAssertEqual(snapshot.recentActivity.last?.toolName, "read")
    XCTAssertEqual(snapshot.recentActivity.last?.toolStatus, "inProgress")
    XCTAssertTrue(snapshot.recentActivity[0].sequence < snapshot.recentActivity[1].sequence)
    let effectiveUpdate = try XCTUnwrap(ISO8601DateFormatter().date(from: snapshot.updatedAt))
    XCTAssertEqual(
      effectiveUpdate.timeIntervalSince1970,
      toolDate.timeIntervalSince1970,
      accuracy: 1
    )
  }

  func testProjectRepositoryAdapterAcceptsStableVolumeAfterDeviceDrift() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let rootURL = fixture.root.appending(path: "adapter-project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let current = try ServiceRootIdentity(capturing: rootURL)
    let volumeUUID = try XCTUnwrap(current.volumeUUID)
    let storedRoot = try ServiceRootIdentity(
      canonicalPath: current.canonicalPath,
      device: current.device == UInt64.max ? 0 : current.device + 1,
      inode: current.inode,
      volumeUUID: volumeUUID
    )
    let projectID = ProjectID(rawValue: "prj-adapter-device-drift")
    let date = Date()
    try await fixture.store.insertProject(
      ServiceProjectRecord(
        id: projectID,
        name: "Adapter Project",
        root: storedRoot,
        accessPolicy: .init(read: .allowed, write: .allowed, network: .denied),
        createdAt: date,
        updatedAt: date
      )
    )
    let adapter = ServiceProjectRepositoryAdapter(projects: fixture.projects)

    let project = try await adapter.project(id: projectID)

    XCTAssertEqual(project?.primaryRoot.canonicalPath, current.canonicalPath)
    XCTAssertEqual(project?.primaryRoot.identity.device, current.device)
    XCTAssertEqual(project?.primaryRoot.identity.inode, current.inode)
  }

  func testToolCatalogSeparatesReadOnlyAndFullExposure() {
    let readOnly = MCPServiceToolCatalog(exposureMode: .readOnly).definitions.map(\.name)
    let full = MCPServiceToolCatalog(exposureMode: .full).definitions.map(\.name)

    XCTAssertEqual(readOnly.count, 14)
    XCTAssertEqual(full.count, 27)
    XCTAssertFalse(readOnly.contains(MCPServiceToolName.submitTask.rawValue))
    XCTAssertFalse(readOnly.contains(MCPServiceToolName.steerTask.rawValue))
    XCTAssertFalse(readOnly.contains(MCPServiceToolName.interruptTask.rawValue))
    XCTAssertFalse(readOnly.contains(MCPServiceToolName.directWriteProjectFile.rawValue))
    XCTAssertTrue(readOnly.contains(MCPServiceToolName.getProjectChanges.rawValue))
    XCTAssertTrue(readOnly.contains(MCPServiceToolName.listProjectCommands.rawValue))
    XCTAssertTrue(full.contains(MCPServiceToolName.submitTask.rawValue))
    XCTAssertTrue(full.contains(MCPServiceToolName.directWriteProjectFile.rawValue))
    XCTAssertFalse(full.contains("resolve_approval"))
  }

  func testConcurrentModelLookupsShareOneCatalogSpawnWithinTTL() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let spawnLog = fixture.root.appending(path: "catalog-spawns.txt").path
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceCountingModelCatalogScript(spawnLog: spawnLog)
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))

    try await withThrowingTaskGroup(of: [String].self) { group in
      for _ in 0..<4 {
        group.addTask {
          try await application.serviceModels(deadline: deadline).models
            .map(\.modelID)
        }
      }
      var firstResult: [String]?
      for try await models in group {
        if let first = firstResult {
          XCTAssertEqual(models, first)
        } else {
          firstResult = models
        }
      }
      XCTAssertEqual(firstResult?.isEmpty, false)
    }

    let spawns = try String(contentsOfFile: spawnLog, encoding: .utf8)
      .split(separator: "\n").count
    XCTAssertEqual(spawns, 1, "The model catalog must spawn codex app-server once per TTL.")
  }

  func testChatGPTSubmissionWaitsForLocalApprovalBeforeStartingCodex() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let gptOnlyInstructions = "GPT only: explain the plugin call before using it."
    try await application.setServiceCustomInstructions(
      gptOnlyInstructions,
      deadline: deadline
    )
    let storedInstructions = try await application.serviceCustomInstructions(deadline: deadline)
    XCTAssertEqual(storedInstructions, gptOnlyInstructions)

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Implement the requested feature.",
        acceptanceCriteria: ["The relevant tests pass."],
        clientRequestID: "chatgpt-request-1"
      ),
      deadline: deadline
    )

    XCTAssertEqual(receipt.taskID, "tsk-service-app")
    XCTAssertEqual(receipt.status, ServiceTaskStatus.awaitingLocalApproval.rawValue)
    XCTAssertTrue(receipt.localApprovalRequired)
    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.executionModel, "execution-model")
    XCTAssertEqual(task.source, .mcpClient)
    XCTAssertEqual(task.sourceClientID, MCPClientID.chatGPT.rawValue)
    XCTAssertEqual(task.executionEffort, "high")
    XCTAssertEqual(task.supervisorModel, "gpt-5.6-luna")
    XCTAssertEqual(task.supervisorEffort, "medium")
    XCTAssertEqual(task.permissionMode, .workspaceWrite)
    XCTAssertTrue(task.prompt.contains("Acceptance criteria:"))
    XCTAssertTrue(task.prompt.contains("The relevant tests pass."))
    XCTAssertFalse(task.prompt.contains(gptOnlyInstructions))
    XCTAssertNil(task.state.codexThreadID)
    XCTAssertNil(task.state.codexTurnID)

    let snapshot = try await application.serviceTask(
      taskID: receipt.taskID,
      recentEventLimit: 20,
      deadline: deadline
    )
    XCTAssertEqual(snapshot.status, ServiceTaskStatus.awaitingLocalApproval.rawValue)
    XCTAssertEqual(snapshot.source, ServiceTaskSource.mcpClient.rawValue)
    XCTAssertEqual(snapshot.sourceClientID, MCPClientID.chatGPT.rawValue)
    XCTAssertEqual(snapshot.executionModel, "execution-model")
    XCTAssertEqual(snapshot.executionEffort, "high")
    XCTAssertEqual(
      snapshot.recentEvents.map(\.kind),
      [ServiceTaskEventKind.taskCreated.rawValue]
    )
    XCTAssertTrue(snapshot.localApprovalRequired)

    let pending = try await application.pendingTaskStartApprovals()
    let approval = try XCTUnwrap(pending.first)
    XCTAssertEqual(approval.taskID, receipt.taskID)
    XCTAssertEqual(approval.projectID, fixture.project.id.rawValue)
    XCTAssertEqual(approval.prompt, task.prompt)
    let waitingStatus = try await application.serviceStatus(deadline: deadline)
    XCTAssertEqual(waitingStatus.executionState, "pending")
    XCTAssertEqual(waitingStatus.pendingApprovalCount, 1)

    try await application.resolveTaskStartApproval(
      taskID: task.id,
      approvalID: approval.approvalID,
      approved: true,
      deadline: deadline
    )

    let startedValue = try await fixture.tasks.task(id: task.id)
    let started = try XCTUnwrap(startedValue)
    XCTAssertEqual(started.state.status, .running)
    XCTAssertEqual(started.state.codexThreadID, "thread-execution")
    XCTAssertEqual(started.state.codexTurnID, "turn-execution")
    let approvalsAfterStart = try await application.pendingTaskStartApprovals()
    XCTAssertTrue(approvalsAfterStart.isEmpty)
    let eventsAfterStart = try await fixture.tasks.events(taskID: task.id, limit: 20)
    XCTAssertEqual(
      eventsAfterStart.map(\.kind),
      [.taskCreated, .taskApproved, .executionStarted]
    )
    do {
      try await application.resolveTaskStartApproval(
        taskID: task.id,
        approvalID: approval.approvalID,
        approved: true,
        deadline: deadline
      )
      XCTFail("Expected an already consumed task approval to expire")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .approvalExpired)
    }
    let runningStatus = try await application.serviceStatus(deadline: deadline)
    XCTAssertEqual(runningStatus.executionState, "active")
    XCTAssertEqual(runningStatus.pendingApprovalCount, 0)
  }

  func testDenyingChatGPTTaskStartApprovalDoesNotStartCodex() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Do not start this task."
      ),
      deadline: deadline
    )
    let approvals = try await application.pendingTaskStartApprovals()
    let approval = try XCTUnwrap(approvals.first)

    try await application.resolveTaskStartApproval(
      taskID: TaskID(rawValue: receipt.taskID),
      approvalID: approval.approvalID,
      approved: false,
      deadline: deadline
    )

    let taskValue = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(taskValue)
    XCTAssertEqual(task.state.status, .failed)
    XCTAssertEqual(task.state.failureCode, "local_approval_denied")
    XCTAssertEqual(task.state.resultSummary, "The local user denied this provider invocation.")
    XCTAssertNil(task.state.codexThreadID)
    XCTAssertNil(task.state.codexTurnID)
    let approvalsAfterDenial = try await application.pendingTaskStartApprovals()
    XCTAssertTrue(approvalsAfterDenial.isEmpty)
    let snapshot = try await application.serviceTask(
      taskID: receipt.taskID,
      recentEventLimit: 20,
      deadline: deadline
    )
    XCTAssertEqual(snapshot.status, ServiceTaskStatus.failed.rawValue)
    XCTAssertEqual(snapshot.failureCode, "local_approval_denied")
    XCTAssertEqual(snapshot.resultSummary, "The local user denied this provider invocation.")
  }

  func testConcurrentTaskStartApprovalIsConsumedOnce() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Start this task exactly once."
      ),
      deadline: deadline
    )
    let approvals = try await application.pendingTaskStartApprovals()
    let approval = try XCTUnwrap(approvals.first)

    let outcomes = await withTaskGroup(
      of: BridgeMCPQueryError?.self,
      returning: [BridgeMCPQueryError?].self
    ) { group in
      for _ in 0..<2 {
        group.addTask {
          do {
            try await application.resolveTaskStartApproval(
              taskID: TaskID(rawValue: receipt.taskID),
              approvalID: approval.approvalID,
              approved: true,
              deadline: deadline
            )
            return nil
          } catch {
            return error as? BridgeMCPQueryError
          }
        }
      }
      var values: [BridgeMCPQueryError?] = []
      for await value in group {
        values.append(value)
      }
      return values
    }

    XCTAssertEqual(outcomes.compactMap { $0 }, [.approvalExpired])
    let taskValue = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(taskValue)
    XCTAssertEqual(task.state.status, .running)
    let events = try await fixture.tasks.events(taskID: task.id, limit: 20)
    XCTAssertEqual(events.filter { $0.kind == .taskApproved }.count, 1)
    XCTAssertEqual(events.filter { $0.kind == .executionStarted }.count, 1)
  }

  func testSubmissionWithoutProjectUsesWorkbenchSelection() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    try await application.serviceSetWorkbenchProjectID(
      fixture.project.id.rawValue,
      deadline: deadline
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        prompt: "Use the workbench project by default.",
        clientRequestID: "workbench-default-request"
      ),
      deadline: deadline
    )

    let stored = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let selectedProjectID = try await application.serviceWorkbenchProjectID(deadline: deadline)
    XCTAssertEqual(stored?.projectID, fixture.project.id)
    XCTAssertEqual(selectedProjectID, fixture.project.id.rawValue)
  }

  func testExplicitSubmissionProjectOverridesWorkbenchSelection() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let secondRoot = FileManager.default.temporaryDirectory.appending(
      path: "bridge-service-application-second-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: secondRoot) }
    let secondProject = try await fixture.projects.register(
      name: "Second Project",
      rootURL: secondRoot,
      id: ProjectID(rawValue: "prj-service-second")
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    try await application.serviceSetWorkbenchProjectID(
      secondProject.id.rawValue,
      deadline: deadline
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Honor the explicit project.",
        clientRequestID: "explicit-project-request"
      ),
      deadline: deadline
    )

    let stored = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    XCTAssertEqual(stored?.projectID, fixture.project.id)
  }

  func testQwenInvocationWaitsForLocalApprovalWithStableClientIdentity() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Read the project through Qwen Studio."
      ),
      invocationContext: MCPInvocationContext(
        clientID: .qwenStudio,
        sessionID: "qwen-session"
      ),
      deadline: deadline
    )

    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.source, .mcpClient)
    XCTAssertEqual(task.sourceClientID, MCPClientID.qwenStudio.rawValue)
    XCTAssertEqual(task.state.status, .awaitingLocalApproval)
    XCTAssertNil(task.state.codexThreadID)
    XCTAssertNil(task.state.codexTurnID)
    XCTAssertTrue(receipt.localApprovalRequired)
    let approvals = try await application.pendingTaskStartApprovals()
    let approval = try XCTUnwrap(approvals.first)
    XCTAssertEqual(approval.taskID, task.id.rawValue)
    XCTAssertEqual(approval.clientID, MCPClientID.qwenStudio.rawValue)

    try await application.resolveTaskStartApproval(
      taskID: task.id,
      approvalID: approval.approvalID,
      approved: false,
      deadline: deadline
    )
    let denied = try await application.serviceTask(
      taskID: task.id.rawValue,
      recentEventLimit: 20,
      deadline: deadline
    )
    XCTAssertEqual(denied.status, ServiceTaskStatus.failed.rawValue)
    XCTAssertEqual(denied.sourceClientID, MCPClientID.qwenStudio.rawValue)
    XCTAssertEqual(denied.failureCode, "local_approval_denied")
    XCTAssertEqual(denied.resultSummary, "The local user denied this provider invocation.")
  }

  func testModelPreferencesArePersistedAndUsedForNewTasks() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    let defaults = try await application.serviceModelPreferences(deadline: deadline)
    XCTAssertEqual(
      defaults,
      ServiceModelPreferences(
        executionModel: "execution-model",
        executionEffort: "high",
        supervisorModel: "gpt-5.6-luna",
        supervisorEffort: "medium"
      )
    )

    let configured = ServiceModelPreferences(
      executionModel: "gpt-5.6-luna",
      executionEffort: "medium",
      supervisorModel: "execution-model",
      supervisorEffort: "high"
    )
    try await application.setServiceModelPreferences(configured, deadline: deadline)
    let storedExecutionModel = try await fixture.settings.string(for: .defaultExecutionModel)
    let storedSupervisorEffort = try await fixture.settings.string(for: .defaultSupervisorEffort)
    XCTAssertEqual(
      storedExecutionModel,
      "gpt-5.6-luna"
    )
    XCTAssertEqual(
      storedSupervisorEffort,
      "high"
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Use the configured model defaults."
      ),
      deadline: deadline
    )
    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.executionModel, configured.executionModel)
    XCTAssertEqual(task.executionEffort, configured.executionEffort)
    XCTAssertEqual(task.supervisorModel, configured.supervisorModel)
    XCTAssertEqual(task.supervisorEffort, configured.supervisorEffort)
  }

  func testUnmarkedSubmissionModelFieldsCannotOverrideBridgeDefaults() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    try await application.setServiceModelPreferences(
      ServiceModelPreferences(
        executionModel: "execution-model",
        executionEffort: "high",
        supervisorModel: "gpt-5.6-luna",
        supervisorEffort: "medium"
      ),
      deadline: deadline
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Use the Bridge defaults despite stale client fields.",
        executionModel: "gpt-5.6-luna",
        executionEffort: "medium"
      ),
      deadline: deadline
    )

    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.executionModel, "execution-model")
    XCTAssertEqual(task.executionEffort, "high")
  }

  func testMarkedSubmissionModelOverrideWinsOverBridgeDefaults() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Use the explicitly requested task model.",
        executionModel: "gpt-5.6-luna",
        executionEffort: "medium",
        modelOverride: true
      ),
      deadline: deadline
    )

    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.executionModel, "gpt-5.6-luna")
    XCTAssertEqual(task.executionEffort, "medium")
  }

  func testConfiguredAccessModeAndFastModeApplyToSubmittedTasks() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceFastModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    try await application.setServiceModelPreferences(
      ServiceModelPreferences(
        executionModel: "execution-model",
        executionEffort: "high",
        supervisorModel: "gpt-5.6-luna",
        supervisorEffort: "medium",
        accessMode: .autoReview,
        fastModeEnabled: true
      ),
      deadline: deadline
    )

    let readBack = try await application.serviceModelPreferences(deadline: deadline)
    XCTAssertEqual(readBack.accessMode, .autoReview)
    XCTAssertTrue(readBack.fastModeEnabled)

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Use the configured execution posture."
      ),
      deadline: deadline
    )
    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.accessMode, .autoReview)
    XCTAssertTrue(task.fastMode)
  }

  func testFastModeIsIgnoredWhenSelectedModelLacksFastTier() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    try await application.setServiceModelPreferences(
      ServiceModelPreferences(
        executionModel: "execution-model",
        executionEffort: "high",
        supervisorModel: "gpt-5.6-luna",
        supervisorEffort: "medium",
        accessMode: .fullAccess,
        fastModeEnabled: true
      ),
      deadline: deadline
    )

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Fast is configured but unsupported."
      ),
      deadline: deadline
    )
    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertEqual(task.accessMode, .fullAccess)
    XCTAssertFalse(task.fastMode)
  }

  func testDisabledSupervisorSkipsSupervisorForSubmittedTasks() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    try await application.setSupervisorEnabled(false)

    let receipt = try await application.serviceSubmitTask(
      MCPServiceTaskSubmission(
        projectID: fixture.project.id.rawValue,
        prompt: "Implement the requested feature.",
        supervisorModel: "gpt-5.6-luna",
        supervisorEffort: "medium",
        clientRequestID: "disabled-supervisor-request"
      ),
      deadline: deadline
    )
    let storedTask = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(storedTask)
    XCTAssertNil(task.supervisorModel)
    XCTAssertNil(task.supervisorEffort)
    XCTAssertEqual(task.state.supervisorStatus, .disabled)

    let snapshot = try await application.serviceTask(
      taskID: receipt.taskID,
      recentEventLimit: 20,
      deadline: deadline
    )
    XCTAssertEqual(snapshot.supervisorStatus, ServiceSupervisorStatus.disabled.rawValue)
  }

  func testModelPreferencesRejectUnknownModelsWithoutWritingSettings() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    do {
      try await application.setServiceModelPreferences(
        ServiceModelPreferences(
          executionModel: "missing-model",
          executionEffort: "high",
          supervisorModel: "gpt-5.6-luna",
          supervisorEffort: "medium"
        ),
        deadline: deadline
      )
      XCTFail("Expected the unknown model to be rejected")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .contractRejected)
    }
    let storedModel = try await fixture.settings.string(for: .defaultExecutionModel)
    XCTAssertNil(storedModel)
  }

  func testSubmissionIsIdempotentAndChangedPayloadIsRejected() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let original = MCPServiceTaskSubmission(
      projectID: fixture.project.id.rawValue,
      prompt: "Implement one bounded feature.",
      clientRequestID: "same-request"
    )

    let first = try await application.serviceSubmitTask(original, deadline: deadline)
    let replay = try await application.serviceSubmitTask(original, deadline: deadline)
    XCTAssertEqual(replay.taskID, first.taskID)
    XCTAssertTrue(replay.reusedExistingTask)

    do {
      _ = try await application.serviceSubmitTask(
        MCPServiceTaskSubmission(
          projectID: fixture.project.id.rawValue,
          prompt: "Implement a different feature.",
          clientRequestID: "same-request"
        ),
        deadline: deadline
      )
      XCTFail("Expected the idempotency conflict")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .idempotencyConflict)
    }
  }

  func testProjectSearchAndReadUseExistingSecureFileBoundary() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let sourceDirectory = fixture.root.appending(path: "Sources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
    try Data("first line\nneedle value\nthird line\n".utf8).write(
      to: sourceDirectory.appending(path: "Feature.swift")
    )
    try Data("TOKEN=secret\n".utf8).write(to: fixture.root.appending(path: ".env"))
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    let matches = try await application.serviceSearchProjectFiles(
      projectID: fixture.project.id.rawValue,
      query: "needle",
      relativeDirectory: "Sources",
      caseSensitive: false,
      cursor: nil,
      limit: 10,
      deadline: deadline
    )
    XCTAssertEqual(matches.matches.map(\.relativePath), ["Sources/Feature.swift"])
    XCTAssertEqual(matches.matches.first?.lineNumber, 2)

    let page = try await application.serviceReadProjectFile(
      projectID: fixture.project.id.rawValue,
      relativePath: "Sources/Feature.swift",
      startLine: 2,
      lineCount: 1,
      deadline: deadline
    )
    XCTAssertEqual(page.content, "needle value")
    XCTAssertEqual(page.startLine, 2)
    XCTAssertEqual(page.endLine, 2)

    do {
      _ = try await application.serviceReadProjectFile(
        projectID: fixture.project.id.rawValue,
        relativePath: ".env",
        startLine: 1,
        lineCount: 10,
        deadline: deadline
      )
      XCTFail("Expected the sensitive path to be denied")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .pathDenied)
    }
  }

  func testThreadCatalogUsesExactProjectCwdAndBoundedHistory() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let listApplication = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceThreadListScript(root: fixture.root.path)
    )

    let listed = try await listApplication.serviceThreads(
      projectID: fixture.project.id.rawValue,
      cursor: nil,
      limit: 25,
      search: nil,
      deadline: deadline
    )
    XCTAssertEqual(listed.threads.map(\.threadID), ["thread-matching"])

    let readApplication = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceThreadReadScript(root: fixture.root.path)
    )
    let history = try await readApplication.serviceReadThread(
      projectID: fixture.project.id.rawValue,
      threadID: "thread-read",
      detail: .full,
      cursor: nil,
      limit: 1,
      deadline: deadline
    )
    XCTAssertEqual(history.entries.count, 1)
    XCTAssertEqual(history.entries.first?.role, "user")
    XCTAssertEqual(history.nextCursor, "v1.1")
  }

  func testThreadReadRejectsAThreadFromAnotherRoot() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let other = fixture.root.appending(path: "other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceThreadReadScript(
        root: fixture.root.path,
        returnedRoot: other.path
      )
    )

    do {
      _ = try await application.serviceReadThread(
        projectID: fixture.project.id.rawValue,
        threadID: "thread-read",
        detail: .summary,
        cursor: nil,
        limit: 25,
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTFail("Expected the cross-project Thread to be rejected")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .threadNotFound)
    }
  }

  func testThreadReadMapsMissingRemoteThreadToNotFound() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceThreadReadFailureScript(message: "thread not loaded")
    )

    do {
      _ = try await application.serviceReadThread(
        projectID: fixture.project.id.rawValue,
        threadID: "00000000-0000-0000-0000-000000000000",
        detail: .summary,
        cursor: nil,
        limit: 25,
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTFail("Expected a missing Thread")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .threadNotFound)
    }
  }

  func testThreadReadMapsInvalidRemoteThreadIDToNotFound() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceThreadReadFailureScript(message: "invalid thread id: arbitrary")
    )

    do {
      _ = try await application.serviceReadThread(
        projectID: fixture.project.id.rawValue,
        threadID: "arbitrary",
        detail: .summary,
        cursor: nil,
        limit: 25,
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTFail("Expected an invalid Thread ID to be unavailable")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .threadNotFound)
    }
  }

  func testAppThreadCatalogReturnsLegacyChatGPTAndGenericMCPClientThreads() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .chatGPT,
        prompt: "Bridge task",
        executionModel: "execution-model",
        executionEffort: "high",
        permissionMode: .readOnly
      )
    )
    _ = try await fixture.tasks.begin(taskID: TaskID(rawValue: "tsk-service-app"))
    _ = try await fixture.tasks.markExecutionStarted(
      taskID: TaskID(rawValue: "tsk-service-app"),
      threadID: "thread-bridge",
      turnID: "turn-bridge"
    )
    _ = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .mcpClient,
        sourceClientID: MCPClientID.qwenStudio.rawValue,
        prompt: "Qwen task",
        executionModel: "execution-model",
        executionEffort: "high",
        permissionMode: .readOnly
      ),
      taskID: TaskID(rawValue: "tsk-service-app-qwen")
    )
    _ = try await fixture.tasks.begin(taskID: TaskID(rawValue: "tsk-service-app-qwen"))
    _ = try await fixture.tasks.markExecutionStarted(
      taskID: TaskID(rawValue: "tsk-service-app-qwen"),
      threadID: "thread-qwen",
      turnID: "turn-qwen"
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceMixedThreadListScript(root: fixture.root.path)
    )

    let page = try await application.serviceAppThreads(
      projectID: fixture.project.id.rawValue,
      cursor: nil,
      limit: 25,
      search: nil,
      deadline: ContinuousClock.now.advanced(by: .seconds(3))
    )

    XCTAssertEqual(Set(page.threads.map(\.threadID)), ["thread-bridge", "thread-qwen"])
  }

  func testAppThreadReadRejectsThreadWithoutChatGPTMCPTask() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceThreadReadScript(root: fixture.root.path)
    )

    do {
      _ = try await application.serviceAppReadThread(
        projectID: fixture.project.id.rawValue,
        threadID: "thread-read",
        detail: .summary,
        cursor: nil,
        limit: 25,
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTFail("Expected a non-MCP Thread to be hidden from the App")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .threadNotFound)
    }
  }

  func testProjectCommandsRoundTripThroughTheApplication() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    let initial = try await application.serviceProjectCommands(
      projectID: fixture.project.id.rawValue,
      deadline: deadline
    )
    XCTAssertEqual(initial.commandMode, "safe")
    XCTAssertTrue(initial.commands.isEmpty)
    XCTAssertTrue(
      initial.builtInCommands.contains {
        $0.executable == "git" && $0.argumentsPrefix == ["status"]
      })
    XCTAssertFalse(
      initial.builtInCommands.contains {
        $0.executable == "npm" && $0.argumentsPrefix == ["run", "build"]
      })
    XCTAssertEqual(initial.recommendedUsage["swift_build"]?.argv, ["swift", "build"])
    XCTAssertNil(initial.recommendedUsage["swift_build"]?.commandID)

    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .safe,
      workspaceCommands: [
        try ServiceWorkspaceCommand(
          id: "wcmd-tests",
          name: "Codex Bridge Tests",
          executable: "Scripts/with-xcode.sh",
          arguments: ["swift", "test", "--package-path", "Packages/BridgeCore"],
          requiresNetwork: false
        ),
        try ServiceWorkspaceCommand(
          id: "wcmd-deploy",
          name: "Deploy",
          executable: "/usr/bin/make",
          arguments: ["deploy"],
          requiresNetwork: true,
          risk: .elevated
        ),
      ],
      projectID: fixture.project.id
    )

    let commands = try await application.serviceProjectCommands(
      projectID: fixture.project.id.rawValue,
      deadline: deadline
    )
    XCTAssertEqual(commands.commandMode, "safe")
    XCTAssertEqual(commands.commands.map(\.commandID), ["wcmd-tests", "wcmd-deploy"])
    XCTAssertEqual(commands.commands[0].name, "Codex Bridge Tests")
    XCTAssertEqual(commands.commands[1].risk, "elevated")
    XCTAssertTrue(commands.commands[1].requiresNetwork)
    XCTAssertNotNil(commands.recommendedUsage["swift_build"])
    XCTAssertNotNil(commands.recommendedUsage["swift_test"])
    XCTAssertEqual(
      commands.recommendedUsage["wcmd-tests"]?.argv,
      [
        "Scripts/with-xcode.sh", "swift", "test", "--package-path", "Packages/BridgeCore",
      ]
    )
    XCTAssertEqual(commands.recommendedUsage["wcmd-tests"]?.commandID, "wcmd-tests")
    XCTAssertNil(commands.recommendedUsage["wcmd-deploy"])

    let detail = try await application.serviceProject(
      projectID: fixture.project.id.rawValue,
      deadline: deadline
    )
    let workspace = try XCTUnwrap(detail.directWorkspace)
    XCTAssertEqual(workspace.fileWritePermission, "requiresLocalApproval")
    XCTAssertEqual(workspace.commandMode, "safe")
    XCTAssertEqual(workspace.commands.count, 2)

    _ = try await fixture.projects.updateAccessPolicy(
      ProjectAccessPolicy(read: .allowed, write: .denied, network: .allowed),
      projectID: fixture.project.id
    )
    let denied = try await application.serviceProjectCommands(
      projectID: fixture.project.id.rawValue,
      deadline: deadline
    )
    XCTAssertTrue(denied.recommendedUsage.isEmpty)
  }

  func testAdditiveDirectResponseFieldsDecodeLegacyPayloads() throws {
    let commands = try JSONDecoder().decode(
      MCPProjectCommands.self,
      from: Data(#"{"command_mode":"safe","commands":[]}"#.utf8)
    )
    XCTAssertTrue(commands.builtInCommands.isEmpty)

    let move = try JSONDecoder().decode(
      MCPDirectManagePathReceipt.self,
      from: Data(
        #"{"relative_path":"old.txt","operation":"move_file","byte_count":3}"#.utf8)
    )
    XCTAssertEqual(move.sourceRelativePath, "old.txt")
    XCTAssertNil(move.destinationRelativePath)
  }

  func testDirectWriteAllowsSourceCodePathsAndReturnsStructuredCredentialError() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(3)))
    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .full)

    let source = #"execFileSync("/bin/sh", ["-c", input]);"#
    let success = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directWriteProjectFile.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "relative_path": .string("command.js"),
          "mode": .string("create"),
          "content": .string(source),
        ]
      ))
    XCTAssertEqual(success.isError, false)
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appendingPathComponent("command.js"), encoding: .utf8),
      source
    )

    let denied = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directWriteProjectFile.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "relative_path": .string("credential.js"),
          "mode": .string("create"),
          "content": .string(#"const api_key = "definitely-secret";"#),
        ]
      ))
    XCTAssertEqual(denied.isError, true)
    XCTAssertEqual(
      denied.structuredContent?.objectValue?["error"]?.objectValue?["code"],
      .string("unsafe_content_detected")
    )
  }

  func testDirectPatchAcceptsUnifiedDiffAndReturnsActionableInvalidPatchError() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(3)))
    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .full)
    let target = fixture.root.appendingPathComponent("patch-target.txt")
    try Data("alpha\nold\nomega\n".utf8).write(to: target)

    let success = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directApplyProjectPatch.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "patch": .string(
            "--- a/patch-target.txt\n+++ b/patch-target.txt\n"
              + "@@ -1,3 +1,3 @@\n alpha\n-old\n+new\n omega\n"
          ),
        ]
      ))

    XCTAssertEqual(success.isError, false)
    XCTAssertEqual(
      success.structuredContent?.objectValue?["receipt_type"], .string("file_mutation"))
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "alpha\nnew\nomega\n")

    let invalid = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directApplyProjectPatch.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "patch": .string("not a patch"),
        ]
      ))
    XCTAssertEqual(invalid.isError, true)
    let error = invalid.structuredContent?.objectValue?["error"]?.objectValue
    XCTAssertEqual(error?["code"], .string("invalid_patch_syntax"))
    XCTAssertEqual(error?["category"], .string("caller_error"))
    XCTAssertEqual(error?["retryable"], .bool(false))
    XCTAssertEqual(error?["next_action"], .string("fix_patch_syntax"))
    XCTAssertTrue(error?["message"]?.stringValue?.contains("standard ---/+++") == true)

    let invalidArguments = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directApplyProjectPatch.rawValue,
        arguments: ["patch": .string("not a patch")]
      ))
    XCTAssertEqual(invalidArguments.isError, true)
    let argumentError = invalidArguments.structuredContent?.objectValue?["error"]?.objectValue
    XCTAssertEqual(argumentError?["code"], .string("invalid_arguments"))
    XCTAssertEqual(argumentError?["category"], .string("caller_error"))
    XCTAssertEqual(argumentError?["next_action"], .string("fix_tool_arguments"))

    let absolutePath = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directApplyProjectPatch.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "patch": .string("*** Add File: /tmp/outside.txt\n@@\n+blocked"),
        ]
      ))
    let absolutePathError =
      absolutePath.structuredContent?.objectValue?["error"]?.objectValue
    XCTAssertEqual(absolutePathError?["code"], .string("path_forbidden"))
    XCTAssertEqual(absolutePathError?["category"], .string("policy_denied"))

    let missingContext = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directApplyProjectPatch.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "patch": .string(
            "*** Update File: patch-target.txt\n@@\n-missing value\n+replacement"
          ),
        ]
      ))
    let missingError = missingContext.structuredContent?.objectValue?["error"]?.objectValue
    XCTAssertEqual(missingError?["code"], .string("patch_context_not_found"))
    XCTAssertEqual(missingError?["category"], .string("state_conflict"))
    XCTAssertEqual(missingError?["retryable"], .bool(true))
    XCTAssertEqual(
      missingError?["next_action"], .string("read_file_and_retry_smaller_patch"))

    try Data("repeat\nrepeat\n".utf8).write(to: target)
    let nonUniqueContext = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directApplyProjectPatch.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "patch": .string("*** Update File: patch-target.txt\n@@\n-repeat\n+changed"),
        ]
      ))
    let nonUniqueError =
      nonUniqueContext.structuredContent?.objectValue?["error"]?.objectValue
    XCTAssertEqual(nonUniqueError?["code"], .string("patch_context_non_unique"))
    XCTAssertEqual(nonUniqueError?["category"], .string("state_conflict"))
  }

  func testDirectWriteStdinClosesEOFAndFlushesGrepThroughMCPDispatcher() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(3)))
    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .full)

    let rejectedTTY = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directExecCommand.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "argv": .array([.string("/usr/bin/grep"), .string("needle")]),
          "tty": .bool(true),
        ]
      ))
    XCTAssertEqual(rejectedTTY.isError, true)
    XCTAssertEqual(
      rejectedTTY.structuredContent?.objectValue?["error"]?.objectValue?["code"],
      .string("invalid_arguments")
    )

    let unregistered = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directExecCommand.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "argv": .array([
            .string(
              "/Volumes/fanch/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild")
          ]),
        ]
      ))
    let commandError = unregistered.structuredContent?.objectValue?["error"]?.objectValue
    XCTAssertEqual(commandError?["code"], .string("command_not_registered"))
    XCTAssertEqual(commandError?["category"], .string("policy_denied"))
    XCTAssertEqual(commandError?["next_action"], .string("list_project_commands"))

    let launched = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directExecCommand.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "argv": .array([.string("/usr/bin/grep"), .string("needle")]),
          "yield_time_ms": .int(0),
          "timeout_ms": .int(5_000),
        ]
      ))
    let sessionID = try XCTUnwrap(
      launched.structuredContent?.objectValue?["session_id"]?.stringValue)
    XCTAssertEqual(
      launched.structuredContent?.objectValue?["receipt_type"], .string("direct_command"))

    let written = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directWriteStdin.rawValue,
        arguments: [
          "session_id": .string(sessionID),
          "data": .string("ignored\nneedle value\n"),
          "close_stdin": .bool(true),
        ]
      ))
    XCTAssertEqual(written.structuredContent?.objectValue?["bytes_written"], .int(21))
    XCTAssertEqual(written.structuredContent?.objectValue?["stdin_closed"], .bool(true))
    XCTAssertEqual(written.structuredContent?.objectValue?["session_id"], .string(sessionID))
    XCTAssertEqual(
      written.structuredContent?.objectValue?["receipt_type"],
      .string("direct_command_input")
    )

    let output = try await waitForCommand(
      application,
      sessionID: sessionID,
      deadline: ContinuousClock.now.advanced(by: .seconds(5))
    )
    XCTAssertEqual(output.exitCode, 0)
    XCTAssertTrue(output.tail.contains("needle value"))
    await application.directCommands.cancelAll()
  }

  func testDirectReadTimeoutDoesNotChangeCommandStateAndTerminalInterruptIsIdempotent()
    async throws
  {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(3)))
    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .full)

    let launched = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directExecCommand.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "argv": .array([.string("/usr/bin/grep"), .string("needle")]),
          "yield_time_ms": .int(0),
          "timeout_ms": .int(5_000),
        ]
      ))
    let sessionID = try XCTUnwrap(
      launched.structuredContent?.objectValue?["session_id"]?.stringValue)

    let read = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directReadCommand.rawValue,
        arguments: [
          "session_id": .string(sessionID),
          "wait_timeout_ms": .int(50),
        ]
      ))
    let readContent = try XCTUnwrap(read.structuredContent?.objectValue)
    XCTAssertEqual(readContent["status"], .string("running"))
    XCTAssertEqual(readContent["command_status"], .string("running"))
    XCTAssertEqual(readContent["timed_out"], .bool(false))
    XCTAssertEqual(readContent["command_timed_out"], .bool(false))
    XCTAssertEqual(readContent["read_timeout"], .bool(true))
    XCTAssertNotNil(readContent["execution_environment"])
    XCTAssertEqual(readContent["receipt_type"], .string("direct_command"))

    _ = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directWriteStdin.rawValue,
        arguments: [
          "session_id": .string(sessionID),
          "close_stdin": .bool(true),
        ]
      ))
    let final = try await waitForCommand(
      application,
      sessionID: sessionID,
      deadline: ContinuousClock.now.advanced(by: .seconds(5))
    )
    let interrupted = try await application.serviceDirectInterruptCommand(
      sessionID: sessionID,
      deadline: ContinuousClock.now.advanced(by: .seconds(3))
    )

    XCTAssertEqual(final.status, "ended")
    XCTAssertEqual(interrupted.status, "ended")
    XCTAssertEqual(interrupted.exitCode, final.exitCode)
    await application.directCommands.cancelAll()
  }

  func testReadOnlyDispatcherRejectsEveryFullOnlyToolEvenWhenCalledByName() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .readOnly)
    let visible = Set(
      MCPServiceToolCatalog(exposureMode: .readOnly).definitions.map(\.name)
    )
    let hidden = MCPServiceToolName.allCases.filter { !visible.contains($0.rawValue) }

    XCTAssertFalse(hidden.isEmpty)
    for name in hidden {
      do {
        _ = try await dispatcher.call(.init(name: name.rawValue))
        XCTFail("Read-only mode accepted hidden tool \(name.rawValue)")
      } catch let error as MCPError {
        guard case .invalidParams = error else {
          return XCTFail("Unexpected error for \(name.rawValue): \(error)")
        }
      }
    }
  }

  func testMissingReadablePathIsNotReportedAsPolicyDenial() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    do {
      _ = try await application.serviceReadProjectFile(
        projectID: fixture.project.id.rawValue,
        relativePath: "missing.txt",
        startLine: 1,
        lineCount: 10,
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTFail("Expected pathNotFound")
    } catch let error as BridgeMCPQueryError {
      XCTAssertEqual(error, .pathNotFound)
    }
  }

  func testMoveReceiptIncludesNormalizedDestinationAndContentRevision() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(3)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    let write = try await application.serviceDirectWriteFile(
      MCPDirectWriteRequest(
        projectID: fixture.project.id.rawValue,
        relativePath: "source.txt",
        mode: "create",
        content: "move me"
      ),
      deadline: deadline
    )
    let moved = try await application.serviceDirectManagePath(
      MCPDirectManagePathRequest(
        projectID: fixture.project.id.rawValue,
        action: "move_file",
        relativePath: "source.txt",
        destinationRelativePath: "destination.txt",
        sourceExpectedSHA256: write.newSHA256,
        clientRequestID: "move-receipt"
      ),
      deadline: deadline
    )
    XCTAssertEqual(moved.sourceRelativePath, "source.txt")
    XCTAssertEqual(moved.destinationRelativePath, "destination.txt")
    XCTAssertEqual(moved.sha256, write.newSHA256)
  }

  func testAgentReachGetsControlledBuiltInActions() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let root = fixture.root.appending(path: "skills/agent-reach", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("---\nname: agent-reach\ndescription: test\n---\n".utf8)
      .write(to: root.appendingPathComponent("SKILL.md"))
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    let list = try await application.serviceListSkills(
      projectID: fixture.project.id.rawValue,
      deadline: ContinuousClock.now.advanced(by: .seconds(3))
    )
    let agentReach = try XCTUnwrap(list.skills.first { $0.name == "agent-reach" })
    XCTAssertTrue(
      agentReach.actions.contains { action in
        action.name == "doctor" && action.commandPrefix == ["agent-reach", "doctor", "--json"]
          && action.networkRequirement == .required
      })
    XCTAssertTrue(agentReach.actions.contains { $0.name == "reddit_search" })
    XCTAssertFalse(agentReach.actions.contains { $0.name == "install" })
  }

  func testStrictSDKClientCallsLightweightServiceOverLoopbackHTTP() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let secret = String(repeating: "S", count: 43)
    let server = MCPBridgeServer(
      appVersion: "0.2.0",
      service: application,
      exposureMode: .full,
      httpConfiguration: try MCPHTTPConfiguration(pathSecret: secret)
    )
    let endpoint = try await server.start()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let transport = HTTPClientTransport(
      endpoint: endpoint.localURL,
      configuration: configuration,
      streaming: false,
      sseInitializationTimeout: 1
    )
    let client = Client(
      name: "lightweight-service-test",
      version: "1",
      configuration: .strict
    )
    addTeardownBlock {
      await client.disconnect()
      await server.stop()
    }

    _ = try await client.connect(transport: transport)
    let listed = try await client.listTools()
    XCTAssertEqual(
      listed.tools.map(\.name),
      MCPServiceToolCatalog(exposureMode: .full).definitions.map(\.name)
    )
    XCTAssertFalse(listed.tools.contains(where: { $0.name.contains("approval") }))

    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: MCPServiceToolName.submitTask.rawValue,
      arguments: [
        "prompt": .string("Implement the minimal requested change."),
        "client_request_id": .string("loopback-request"),
      ]
    )
    let result = try await context.value
    XCTAssertEqual(result.isError, false)
    XCTAssertEqual(
      result.structuredContent?.objectValue?["receipt_type"], .string("provider_task")
    )
    XCTAssertNotNil(result.structuredContent?.objectValue?["task_id"]?.stringValue)
    XCTAssertEqual(
      result.structuredContent?.objectValue?["status"],
      .string(ServiceTaskStatus.awaitingLocalApproval.rawValue)
    )
    XCTAssertEqual(
      result.structuredContent?.objectValue?["local_approval_required"],
      .bool(true)
    )
  }

  func testRunSkillActionExecutesShebangAndInterpretedScriptsEndToEnd() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .full,
      workspaceCommands: [],
      projectID: fixture.project.id
    )
    let skills = fixture.root.appending(path: "skills", directoryHint: .isDirectory)
      .appending(path: "toolkit", directoryHint: .isDirectory)
    let scripts = skills.appending(path: "scripts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let frontmatter = """
      ---
      name: toolkit
      description: >
        A small E2E toolkit.
      actions:
        - name: greet
          script: scripts/greet.sh
          requires_network: false
        - name: sum
          script: scripts/sum.py
          interpreter: python3
          requires_network: false
        - name: context
          script: scripts/context.mjs
          interpreter: node
          requires_network: false
      ---
      """
    try Data(frontmatter.utf8).write(to: skills.appendingPathComponent("SKILL.md"))
    try Data("#!/bin/sh\necho 'hello from sh'\n".utf8)
      .write(to: scripts.appendingPathComponent("greet.sh"))
    try Data("import sys\nprint('sum=%d' % (int(sys.argv[1]) + int(sys.argv[2])))\n".utf8)
      .write(to: scripts.appendingPathComponent("sum.py"))
    try Data("console.log('context-ok ' + (process.argv[2] || ''));\n".utf8)
      .write(to: scripts.appendingPathComponent("context.mjs"))

    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))

    let greet = try await application.serviceRunSkillAction(
      MCPRunSkillActionRequest(
        skillName: "toolkit",
        actionName: "greet",
        arguments: [],
        projectID: fixture.project.id.rawValue,
        yieldTimeMS: 200,
        timeoutMS: 5_000
      ),
      deadline: deadline
    )
    let greetOutput = try await waitForCommand(
      application, sessionID: greet.sessionID, deadline: deadline)
    XCTAssertEqual(greetOutput.status, "ended")
    XCTAssertEqual(greetOutput.exitCode, 0)
    XCTAssertTrue(greetOutput.tail.contains("hello from sh"))

    let sum = try await application.serviceRunSkillAction(
      MCPRunSkillActionRequest(
        skillName: "toolkit",
        actionName: "sum",
        arguments: ["3", "4"],
        projectID: fixture.project.id.rawValue,
        yieldTimeMS: 200,
        timeoutMS: 5_000
      ),
      deadline: deadline
    )
    let sumOutput = try await waitForCommand(
      application, sessionID: sum.sessionID, deadline: deadline)
    XCTAssertEqual(sumOutput.exitCode, 0)
    XCTAssertTrue(sumOutput.tail.contains("sum=7"))

    let context = try await application.serviceRunSkillAction(
      MCPRunSkillActionRequest(
        skillName: "toolkit",
        actionName: "context",
        arguments: ["arg1"],
        projectID: fixture.project.id.rawValue,
        yieldTimeMS: 200,
        timeoutMS: 5_000
      ),
      deadline: deadline
    )
    let contextOutput = try await waitForCommand(
      application, sessionID: context.sessionID, deadline: deadline)
    XCTAssertEqual(contextOutput.exitCode, 0)
    XCTAssertTrue(contextOutput.tail.contains("context-ok arg1"))

    do {
      _ = try await application.serviceRunSkillAction(
        MCPRunSkillActionRequest(
          skillName: "toolkit",
          actionName: "does-not-exist",
          arguments: [],
          projectID: fixture.project.id.rawValue,
          yieldTimeMS: 200,
          timeoutMS: 5_000
        ),
        deadline: deadline
      )
      XCTFail("Expected skillActionNotFound for unknown action")
    } catch let error as BridgeMCPQueryError {
      guard case .skillActionNotFound = error else {
        return XCTFail("Expected skillActionNotFound, got \(error)")
      }
    }

    await application.directCommands.cancelAll()
  }

  func testSkillActionNetworkRequirementIsEnforcedForDeniedAndRequired() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.projects.updateAccessPolicy(
      ProjectAccessPolicy(read: .allowed, write: .allowed, network: .allowed),
      projectID: fixture.project.id
    )
    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .full,
      workspaceCommands: [],
      projectID: fixture.project.id
    )
    let skill = fixture.root.appending(path: "skills/network-test", directoryHint: .isDirectory)
    let scripts = skill.appending(path: "scripts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let frontmatter = """
      ---
      name: network-test
      description: Network enforcement fixture.
      actions:
        - name: denied
          script: scripts/socket.mjs
          interpreter: node
          requires_network: false
        - name: required
          script: scripts/socket.mjs
          interpreter: node
          requires_network: true
      ---
      """
    try Data(frontmatter.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    let script = """
      import net from 'node:net';
      const server = net.createServer();
      server.on('error', error => { console.error(error.code); process.exit(42); });
      server.listen(0, '127.0.0.1', () => { console.log('loopback-ok'); server.close(); });
      """
    try Data(script.utf8).write(to: scripts.appendingPathComponent("socket.mjs"))

    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))

    let denied = try await application.serviceRunSkillAction(
      MCPRunSkillActionRequest(
        skillName: "network-test", actionName: "denied", projectID: fixture.project.id.rawValue,
        yieldTimeMS: 20, timeoutMS: 5_000),
      deadline: deadline
    )
    let deniedOutput = try await waitForCommand(
      application, sessionID: denied.sessionID, deadline: deadline)
    XCTAssertNotEqual(deniedOutput.exitCode, 0)
    XCTAssertFalse(deniedOutput.tail.contains("loopback-ok"))

    let required = try await application.serviceRunSkillAction(
      MCPRunSkillActionRequest(
        skillName: "network-test", actionName: "required",
        projectID: fixture.project.id.rawValue, yieldTimeMS: 20, timeoutMS: 5_000),
      deadline: deadline
    )
    let requiredOutput = try await waitForCommand(
      application, sessionID: required.sessionID, deadline: deadline)
    XCTAssertEqual(requiredOutput.exitCode, 0)
    XCTAssertTrue(requiredOutput.tail.contains("loopback-ok"))

    await application.directCommands.cancelAll()
  }

  func testSupervisorStateIgnoresTerminalDegradedTasksAndMatchesDegradations() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    let initialStatus = try await application.serviceStatus(deadline: deadline)
    XCTAssertEqual(initialStatus.supervisorState, "idle")
    XCTAssertEqual(initialStatus.degradations, [])

    let completedDate = Date()
    let oldTask = try ServiceTaskRecord(
      id: TaskID(rawValue: "tsk-old-degraded"),
      projectID: fixture.project.id,
      source: .mcpClient,
      sourceClientID: MCPClientID.chatGPT.rawValue,
      clientRequestID: "req-1",
      prompt: "Past task",
      executionModel: "gpt-5.6",
      executionEffort: "high",
      supervisorModel: "gpt-5.6-luna",
      supervisorEffort: "medium",
      permissionMode: .workspaceWrite,
      networkAllowed: true,
      state: try ServiceTaskState(
        status: .completed,
        supervisorStatus: .degraded,
        supervisorSummary: "Old supervisor degraded"
      ),
      createdAt: completedDate,
      updatedAt: completedDate
    )
    _ = try await fixture.store.createTask(
      oldTask,
      event: try ServiceTaskEventDraft(
        kind: .taskCreated,
        summary: "Created",
        createdAt: completedDate
      )
    )

    let afterCompletedStatus = try await application.serviceStatus(deadline: deadline)
    XCTAssertEqual(afterCompletedStatus.supervisorState, "idle")
    XCTAssertEqual(afterCompletedStatus.degradations, [])

    let activeDate = Date()
    let activeTask = try ServiceTaskRecord(
      id: TaskID(rawValue: "tsk-active-degraded"),
      projectID: fixture.project.id,
      source: .mcpClient,
      sourceClientID: MCPClientID.chatGPT.rawValue,
      clientRequestID: "req-2",
      prompt: "Active task",
      executionModel: "gpt-5.6",
      executionEffort: "high",
      supervisorModel: "gpt-5.6-luna",
      supervisorEffort: "medium",
      permissionMode: .workspaceWrite,
      networkAllowed: true,
      state: try ServiceTaskState(
        status: .running,
        supervisorStatus: .degraded,
        supervisorSummary: "Active supervisor connection degraded"
      ),
      createdAt: activeDate,
      updatedAt: activeDate
    )
    _ = try await fixture.store.createTask(
      activeTask,
      event: try ServiceTaskEventDraft(
        kind: .taskCreated,
        summary: "Created",
        createdAt: activeDate
      )
    )

    let afterActiveStatus = try await application.serviceStatus(deadline: deadline)
    XCTAssertEqual(afterActiveStatus.supervisorState, "degraded")
    XCTAssertEqual(
      afterActiveStatus.degradations,
      ["Active supervisor connection degraded"]
    )
  }

  func testRunSkillActionThroughMCPToolDispatcherCompletesWithoutTimeout() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    _ = try await fixture.projects.updateAccessPolicy(
      ProjectAccessPolicy(read: .allowed, write: .allowed, network: .allowed),
      projectID: fixture.project.id
    )
    _ = try await fixture.projects.updateWorkspaceConfiguration(
      directCommandMode: .full,
      workspaceCommands: [],
      projectID: fixture.project.id
    )
    let skill = fixture.root.appending(path: "skills/fast-skill", directoryHint: .isDirectory)
    let scripts = skill.appending(path: "scripts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let frontmatter = """
      ---
      name: fast-skill
      description: Fast test skill.
      actions:
        - name: greet
          script: scripts/greet.sh
          interpreter: sh
          requires_network: false
      ---
      """
    try Data(frontmatter.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    let script = """
      #!/bin/sh
      echo "skill-fast-result"
      """
    let scriptURL = scripts.appendingPathComponent("greet.sh")
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto,
      deadline: ContinuousClock.now.advanced(by: .seconds(30))
    )

    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .full)
    let result = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.runSkillAction.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "skill_name": .string("fast-skill"),
          "action_name": .string("greet"),
        ]
      )
    )
    XCTAssertEqual(result.isError, false)
    let outputObj = result.structuredContent?.objectValue
    XCTAssertEqual(outputObj?["receipt_type"], .string("skill_action"))
    XCTAssertEqual(outputObj?["status"], .string("ended"))
    XCTAssertEqual(outputObj?["exit_code"], .int(0))
    let output = outputObj?["output"]?.objectValue
    XCTAssertTrue(output?["tail"]?.stringValue?.contains("skill-fast-result") == true)

    await application.directCommands.cancelAll()
  }

  func testDirectProcessLifetimeDefaultEnvironmentIncludesUserHomeAndLocalBin() {
    let env = DirectProcessLifetime.defaultEnvironment()
    XCTAssertFalse(env["HOME"]?.isEmpty ?? true)
    let path = env["PATH"] ?? ""
    XCTAssertTrue(path.contains(".local/bin"))
    XCTAssertTrue(path.contains("/usr/bin"))
  }

  private func waitForCommand(
    _ application: BridgeServiceApplication,
    sessionID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput {
    while ContinuousClock.now < deadline {
      let output = try await application.serviceDirectReadCommand(
        sessionID: sessionID, deadline: deadline)
      if output.status != "running" { return output }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw BridgeMCPQueryError.timeout
  }
}
