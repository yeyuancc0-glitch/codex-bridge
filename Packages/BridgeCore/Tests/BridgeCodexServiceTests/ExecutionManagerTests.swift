import BridgeCodexService
import BridgeDomain
import BridgeServiceCore
import XCTest

final class ExecutionManagerTests: XCTestCase {
  func testBurstOutputBackpressuresWithoutLosingContentOrCompletion() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-burst-backpressure"
    )
    let manager = makeExecutionManager(
      script: burstyOutputExecutionScript(root: fixture.root.path),
      eventBufferLimit: 1,
      outputBufferLimit: 1
    )
    addTeardownBlock { await manager.shutdown() }

    let handle = try await manager.start(
      try ExecutionRequest(task: task, project: fixture.project)
    )
    try await Task.sleep(for: .milliseconds(100))

    var content = ""
    var completion: String?
    for await event in handle.events {
      switch event {
      case .agentMessageDelta(let delta):
        content.append(delta.delta)
      case .completed(let summary):
        completion = summary
      default:
        break
      }
    }

    XCTAssertEqual(content, "alpha beta gamma")
    XCTAssertEqual(completion, "alpha beta gamma")
  }

  func testUnexpectedProcessExitPreservesSpecificFailureReason() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-process-exit"
    )
    let manager = makeExecutionManager(
      script: unexpectedExitExecutionScript(root: fixture.root.path)
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let failed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .failed
    }

    XCTAssertEqual(failed.state.failureCode, "codex_process_exited")
    XCTAssertEqual(
      failed.state.resultSummary,
      "Codex app-server exited before the active Turn completed (status 23)."
    )
  }

  func testMissingCodexProjectIsCreatedBeforeStartingAssignedThread() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-project-assigned"
    )
    let manager = makeExecutionManager(
      script: projectAssignedExecutionScript(root: fixture.root.path),
      synchronizeCodexProjects: true
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    let binding = try await coordinator.start(taskID: task.id)
    XCTAssertEqual(binding.threadID, "thread-project-assigned")
    XCTAssertEqual(binding.turnID, "turn-project-assigned")

    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "Created the Codex project first.")
  }

  func testUnassignedExistingThreadIsAttachedToMatchingCodexProjectBeforeResume() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-project-resume",
      threadID: "thread-project-resume"
    )
    let manager = makeExecutionManager(
      script: projectAssignedResumeScript(root: fixture.root.path),
      synchronizeCodexProjects: true
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    let binding = try await coordinator.start(taskID: task.id)
    XCTAssertEqual(binding.threadID, "thread-project-resume")
    XCTAssertEqual(binding.turnID, "turn-project-resume")

    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "Resumed inside the Codex project.")
  }

  func testNewThreadUpdatesServiceTaskWithoutLegacyCoordinatorOrPipeline() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-progress"
    )
    let manager = makeExecutionManager(script: newThreadProgressScript(root: fixture.root.path))
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    let binding = try await coordinator.start(taskID: task.id)
    XCTAssertEqual(binding.threadID, "thread-progress")
    XCTAssertEqual(binding.turnID, "turn-progress")

    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.codexThreadID, "thread-progress")
    XCTAssertEqual(completed.state.codexTurnID, "turn-progress")
    XCTAssertEqual(completed.state.currentStep, "Edit Sources/App.swift")
    XCTAssertEqual(completed.state.changedFiles, ["Sources/App.swift"])
    XCTAssertEqual(completed.state.resultSummary, "Implemented the change and verified it.")

    let events = try await fixture.tasks.events(taskID: task.id, limit: 50)
    XCTAssertTrue(events.contains(where: { $0.kind == .executionStarted }))
    XCTAssertTrue(events.contains(where: { $0.kind == .planUpdated }))
    XCTAssertTrue(events.contains(where: { $0.kind == .commandCompleted }))
    XCTAssertTrue(events.contains(where: { $0.kind == .fileChanged }))
    XCTAssertEqual(events.last?.kind, .taskCompleted)

    let messages = try await coordinator.conversationPage(taskID: task.id)
    let command = try XCTUnwrap(messages.first { $0.key == "tool:item-command" })
    XCTAssertEqual(command.kind, .toolCall)
    XCTAssertEqual(command.toolName, "read_files")
    XCTAssertEqual(command.toolStatus, "completed")
    XCTAssertTrue(command.toolArguments?.contains("读取 Sources/App.swift") == true)
    XCTAssertTrue(command.toolArguments?.contains("命令：swift test") == true)

    let fileChange = try XCTUnwrap(messages.first { $0.key == "tool:item-file" })
    XCTAssertEqual(fileChange.kind, .toolCall)
    XCTAssertEqual(fileChange.toolName, "file_change")
    XCTAssertEqual(fileChange.toolStatus, "completed")
    XCTAssertEqual(fileChange.toolArguments, "编辑 Sources/App.swift")
  }

  func testLocalApprovalAllowsCommandAndDeferredCompletionCommitsAfterTaskState() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-approval-allow"
    )
    let manager = makeExecutionManager(
      script: commandApprovalScript(
        root: fixture.root.path,
        expectedDecision: "accept",
        finalMessage: "The approved command completed."
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let approval = try await waitForApproval(coordinator, taskID: task.id)
    XCTAssertEqual(approval.kind, .command)
    XCTAssertEqual(approval.binding.threadID, "thread-approval")
    XCTAssertEqual(approval.binding.turnID, "turn-approval")
    XCTAssertEqual(approval.displayCommand, "[REDACTED]")

    let waiting = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .waitingForCodexApproval
    }
    XCTAssertEqual(waiting.state.status, .waitingForCodexApproval)

    try await coordinator.resolveApproval(
      taskID: task.id,
      approvalID: approval.id,
      decision: .allow
    )

    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "The approved command completed.")
    let events = try await fixture.tasks.events(taskID: task.id, limit: 50)
    XCTAssertTrue(events.contains(where: { $0.kind == .approvalRequested }))
    XCTAssertTrue(
      events.contains(where: {
        $0.kind == .approvalResolved && $0.summary.contains("approved")
      })
    )
  }

  func testSessionApprovalUsesNativeCodexDecisionAndResumesTask() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-approval-session"
    )
    let manager = makeExecutionManager(
      script: commandApprovalScript(
        root: fixture.root.path,
        expectedDecision: "acceptForSession",
        finalMessage: "The session approval resumed execution."
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let approval = try await waitForApproval(coordinator, taskID: task.id)
    XCTAssertTrue(approval.availableDecisions.contains(.allowForSession))

    try await coordinator.resolveApproval(
      taskID: task.id,
      approvalID: approval.id,
      decision: .allowForSession
    )

    let terminal = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status.isTerminal
    }
    XCTAssertEqual(
      terminal.state.status,
      .completed,
      "failure=\(terminal.state.failureCode ?? "nil") summary=\(terminal.state.resultSummary ?? "nil")"
    )
    XCTAssertEqual(terminal.state.resultSummary, "The session approval resumed execution.")
  }

  func testLocalApprovalDenialLetsCodexFinishWithASaferPath() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-approval-deny"
    )
    let manager = makeExecutionManager(
      script: commandApprovalScript(
        root: fixture.root.path,
        expectedDecision: "decline",
        finalMessage: "Used a safer path after the denial."
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let approval = try await waitForApproval(coordinator, taskID: task.id)
    try await coordinator.resolveApproval(
      taskID: task.id,
      approvalID: approval.id,
      decision: .deny
    )

    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.failureCode, nil)
    XCTAssertEqual(completed.state.resultSummary, "Used a safer path after the denial.")
    let events = try await fixture.tasks.events(taskID: task.id, limit: 50)
    XCTAssertTrue(
      events.contains(where: {
        $0.kind == .approvalResolved && $0.summary.contains("safer path")
      })
    )
  }

  func testCollaborationTurnCanRequestApprovalWithoutReplacingPrimaryTurn() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-collaboration"
    )
    let manager = makeExecutionManager(
      script: collaborationApprovalScript(root: fixture.root.path)
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    let binding = try await coordinator.start(taskID: task.id)
    XCTAssertEqual(binding.threadID, "thread-primary")
    XCTAssertEqual(binding.turnID, "turn-primary")

    let approval = try await waitForApproval(coordinator, taskID: task.id)
    XCTAssertEqual(approval.binding.threadID, "thread-child")
    XCTAssertEqual(approval.binding.turnID, "turn-child")
    try await coordinator.resolveApproval(
      taskID: task.id,
      approvalID: approval.id,
      decision: .allow
    )

    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.codexThreadID, "thread-primary")
    XCTAssertEqual(completed.state.codexTurnID, "turn-primary")
    XCTAssertEqual(completed.state.currentStep, nil)
    XCTAssertEqual(completed.state.resultSummary, "The parent integrated the child result.")

    let messages = try await coordinator.conversationPage(taskID: task.id)
    XCTAssertFalse(messages.contains { $0.content.contains("child-only output") })
    XCTAssertTrue(messages.contains { $0.content.contains("parent integrated") })

    let events = try await fixture.tasks.events(taskID: task.id, limit: 50)
    XCTAssertFalse(events.contains { $0.kind == .planUpdated })
    XCTAssertFalse(events.contains { $0.kind == .commandCompleted })
    XCTAssertFalse(messages.contains { $0.key == "tool:child-command" })
    XCTAssertEqual(events.last?.kind, .taskCompleted)
  }

  func testExistingThreadCanBeSteeredAndInterruptedOnlyWithExactTurn() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-resume",
      threadID: "thread-existing"
    )
    let manager = makeExecutionManager(
      script: resumeSteerInterruptExecutionScript(root: fixture.root.path)
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    let binding = try await coordinator.start(taskID: task.id)
    do {
      try await coordinator.steer(
        taskID: task.id,
        expectedTurnID: "wrong-turn",
        text: "Do not broaden the task."
      )
      XCTFail("Expected an exact Turn mismatch")
    } catch {
      XCTAssertEqual(error as? ExecutionServiceError, .bindingMismatch)
    }

    try await coordinator.steer(
      taskID: task.id,
      expectedTurnID: binding.turnID,
      text: "Do not broaden the task."
    )
    try await coordinator.interrupt(taskID: task.id, expectedTurnID: binding.turnID)

    let interrupted = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .interrupted
    }
    XCTAssertEqual(interrupted.state.codexThreadID, "thread-existing")
    XCTAssertEqual(interrupted.state.codexTurnID, "turn-existing")
  }

  func testUnavailableModelFailsTaskAndLeavesNoActiveSession() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-missing-model"
    )
    let manager = makeExecutionManager(script: unavailableModelScript())
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    do {
      _ = try await coordinator.start(taskID: task.id)
      XCTFail("Expected the missing model to fail")
    } catch {
      XCTAssertEqual(error as? ExecutionServiceError, .modelUnavailable("fixture-model"))
    }

    let failed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .failed
    }
    XCTAssertEqual(failed.state.failureCode, "execution_start_failed")
    let active = await manager.hasActiveSession(taskID: task.id)
    XCTAssertFalse(active)
  }

  func testNetworkTaskAcceptsThreadResponseWithoutNetworkAccessEcho() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-network",
      networkAllowed: true
    )
    let manager = makeExecutionManager(script: agentDeltaScript(root: fixture.root.path))
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    let binding = try await coordinator.start(taskID: task.id)
    XCTAssertEqual(binding.threadID, "thread-conversation")

    let completed = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "Final authoritative agent text.")
  }

  func testWrongApprovalIdentifierDoesNotAlterWaitingTask() async throws {
    let fixture = try await makeExecutionFixture(self)
    let task = try await submitStartedExecutionTask(
      fixture: fixture,
      taskID: "tsk-wrong-approval"
    )
    let manager = makeExecutionManager(
      script: commandApprovalScript(
        root: fixture.root.path,
        expectedDecision: "decline",
        finalMessage: "Finished after the correct decision."
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: fixture.tasks,
      projects: fixture.projects,
      execution: manager
    )
    addTeardownBlock { await coordinator.shutdown() }

    _ = try await coordinator.start(taskID: task.id)
    let approval = try await waitForApproval(coordinator, taskID: task.id)
    do {
      try await coordinator.resolveApproval(
        taskID: task.id,
        approvalID: "apr_wrong",
        decision: .allow
      )
      XCTFail("Expected the unknown approval to fail")
    } catch {
      XCTAssertEqual(
        error as? ExecutionServiceError,
        .approvalUnavailable("apr_wrong")
      )
    }
    let waiting = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .waitingForCodexApproval
    }
    XCTAssertEqual(waiting.state.status, .waitingForCodexApproval)

    try await coordinator.resolveApproval(
      taskID: task.id,
      approvalID: approval.id,
      decision: .deny
    )
    _ = try await waitForTask(fixture, taskID: task.id) {
      $0.state.status == .completed
    }
  }
}
