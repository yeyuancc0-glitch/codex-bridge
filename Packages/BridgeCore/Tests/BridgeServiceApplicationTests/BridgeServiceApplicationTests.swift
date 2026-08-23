import BridgeDomain
import BridgeMCP
import BridgeProjects
import BridgeServiceApplication
import BridgeServiceCore
import MCP
import XCTest

final class BridgeServiceApplicationTests: XCTestCase {
  func testToolCatalogSeparatesReadOnlyAndFullExposure() {
    let readOnly = MCPServiceToolCatalog(exposureMode: .readOnly).definitions.map(\.name)
    let full = MCPServiceToolCatalog(exposureMode: .full).definitions.map(\.name)

    XCTAssertEqual(readOnly.count, 13)
    XCTAssertEqual(full.count, 26)
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

  func testMinimalSubmissionUsesCatalogDefaultsAndAutoStartsCodexExecution() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

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
    XCTAssertEqual(receipt.status, ServiceTaskStatus.running.rawValue)
    XCTAssertFalse(receipt.localApprovalRequired)
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
    XCTAssertEqual(task.state.codexThreadID, "thread-execution")
    XCTAssertEqual(task.state.codexTurnID, "turn-execution")

    let snapshot = try await application.serviceTask(
      taskID: receipt.taskID,
      recentEventLimit: 20,
      deadline: deadline
    )
    XCTAssertEqual(snapshot.status, ServiceTaskStatus.running.rawValue)
    XCTAssertEqual(snapshot.source, ServiceTaskSource.mcpClient.rawValue)
    XCTAssertEqual(snapshot.sourceClientID, MCPClientID.chatGPT.rawValue)
    XCTAssertEqual(snapshot.executionModel, "execution-model")
    XCTAssertEqual(snapshot.executionEffort, "high")
    XCTAssertEqual(
      snapshot.recentEvents.map(\.kind),
      [
        ServiceTaskEventKind.taskCreated.rawValue,
        ServiceTaskEventKind.executionStarting.rawValue,
        ServiceTaskEventKind.executionStarted.rawValue,
      ]
    )
    XCTAssertFalse(snapshot.localApprovalRequired)

    let status = try await application.serviceStatus(deadline: deadline)
    XCTAssertEqual(status.executionState, "active")
    XCTAssertEqual(status.pendingApprovalCount, 0)
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

  func testQwenInvocationPersistsGenericMCPSourceAndStableClientIdentity() async throws {
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

    let detail = try await application.serviceProject(
      projectID: fixture.project.id.rawValue,
      deadline: deadline
    )
    let workspace = try XCTUnwrap(detail.directWorkspace)
    XCTAssertEqual(workspace.fileWritePermission, "requiresLocalApproval")
    XCTAssertEqual(workspace.commandMode, "safe")
    XCTAssertEqual(workspace.commands.count, 2)
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
    XCTAssertEqual(error?["code"], .string("invalid_patch"))
    XCTAssertTrue(error?["message"]?.stringValue?.contains("standard ---/+++") == true)
  }

  func testDirectWriteStdinClosesEOFAndFlushesGrepThroughMCPDispatcher() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    try await application.serviceSetDirectApprovalMode(
      .auto, deadline: ContinuousClock.now.advanced(by: .seconds(3)))
    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .full)

    do {
      _ = try await dispatcher.call(
        .init(
          name: MCPServiceToolName.directExecCommand.rawValue,
          arguments: [
            "project_id": .string(fixture.project.id.rawValue),
            "argv": .array([.string("/usr/bin/grep"), .string("needle")]),
            "tty": .bool(true),
          ]
        ))
      XCTFail("Expected tty=true to be rejected")
    } catch let error as MCPError {
      guard case .invalidParams = error else {
        return XCTFail("Unexpected MCP error: \(error)")
      }
    }

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

    let output = try await waitForCommand(
      application,
      sessionID: sessionID,
      deadline: ContinuousClock.now.advanced(by: .seconds(5))
    )
    XCTAssertEqual(output.exitCode, 0)
    XCTAssertTrue(output.tail.contains("needle value"))
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
      result.structuredContent?.objectValue?["status"],
      .string(ServiceTaskStatus.running.rawValue)
    )
    XCTAssertEqual(
      result.structuredContent?.objectValue?["local_approval_required"],
      .bool(false)
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
