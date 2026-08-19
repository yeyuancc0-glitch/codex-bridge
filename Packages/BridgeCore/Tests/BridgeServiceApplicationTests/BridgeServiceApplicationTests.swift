import BridgeDomain
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import MCP
import XCTest

final class BridgeServiceApplicationTests: XCTestCase {
  func testToolCatalogSeparatesReadOnlyAndFullExposure() {
    let readOnly = MCPServiceToolCatalog(exposureMode: .readOnly).definitions.map(\.name)
    let full = MCPServiceToolCatalog(exposureMode: .full).definitions.map(\.name)

    XCTAssertEqual(readOnly.count, 11)
    XCTAssertEqual(full.count, 22)
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
        "project_id": .string(fixture.project.id.rawValue),
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
}
