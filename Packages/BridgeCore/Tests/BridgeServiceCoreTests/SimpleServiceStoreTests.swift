import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import GRDB
import XCTest

final class SimpleServiceStoreTests: XCTestCase {
  func testProjectTaskStateAndEventsSurviveRestart() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let clock = ServiceCoreTestClock()
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let projects = ServiceProjectService(
      store: store,
      makeProjectID: { ProjectID(rawValue: "prj-persisted") },
      now: clock.next
    )
    let project = try await projects.register(
      name: "Persisted project",
      rootURL: fixture.firstProjectURL
    )
    let tasks = ServiceTaskManager(
      store: store,
      makeTaskID: { TaskID(rawValue: "tsk-persisted") },
      now: clock.next
    )

    let created = try await tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .chatGPT,
        clientRequestID: "request-persisted",
        prompt: "Update the project and run its focused tests.",
        executionModel: "codex-model",
        executionEffort: "high",
        supervisorModel: "supervisor-model",
        supervisorEffort: "medium",
        permissionMode: .workspaceWrite
      )
    )
    _ = try await tasks.approve(taskID: created.task.id)
    _ = try await tasks.markExecutionStarted(
      taskID: created.task.id,
      threadID: "thr-persisted",
      turnID: "turn-persisted"
    )
    _ = try await tasks.updatePlan(
      taskID: created.task.id,
      currentStep: "Run the focused service tests."
    )
    _ = try await tasks.recordChangedFiles(
      taskID: created.task.id,
      relativePaths: ["Sources/Feature.swift", "Tests/FeatureTests.swift"]
    )
    _ = try await tasks.complete(
      taskID: created.task.id,
      resultSummary: "The change and focused tests completed.",
      changedFiles: ["Sources/Feature.swift", "Tests/FeatureTests.swift"]
    )
    _ = try await tasks.updateSupervisor(
      taskID: created.task.id,
      status: .completed,
      summary: "The final result matches the requested scope."
    )

    let reopened = try SimpleServiceStore(path: fixture.databasePath)
    let storedProject = try await reopened.project(id: project.id)
    let storedTask = try await reopened.task(id: created.task.id)
    let events = try await reopened.events(taskID: created.task.id)

    XCTAssertEqual(storedProject, project)
    XCTAssertEqual(storedTask?.state.status, .completed)
    XCTAssertEqual(storedTask?.state.supervisorStatus, .completed)
    XCTAssertEqual(storedTask?.state.codexThreadID, "thr-persisted")
    XCTAssertEqual(storedTask?.state.codexTurnID, "turn-persisted")
    XCTAssertEqual(
      storedTask?.state.changedFiles,
      ["Sources/Feature.swift", "Tests/FeatureTests.swift"]
    )
    XCTAssertEqual(
      events.map(\.kind),
      [
        .taskCreated,
        .taskApproved,
        .executionStarted,
        .planUpdated,
        .fileChanged,
        .taskCompleted,
        .supervisorDecision,
      ]
    )
    let activeWrite = try await reopened.activeWriteTask(projectID: project.id)
    XCTAssertNil(activeWrite)
  }

  func testClientRequestIdempotencyReusesTaskAndRejectsChangedPayload() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(
      id: "prj-idempotent",
      rootURL: fixture.firstProjectURL
    )
    try await store.insertProject(project)
    let first = try makeServiceTask(
      id: "tsk-idempotent-first",
      projectID: project.id,
      clientRequestID: "request-same",
      permissionMode: .readOnly
    )
    let repeated = try makeServiceTask(
      id: "tsk-idempotent-second",
      projectID: project.id,
      date: first.createdAt.addingTimeInterval(10),
      clientRequestID: "request-same",
      permissionMode: .readOnly
    )

    let created = try await store.createTask(first, event: creationEvent(at: first.createdAt))
    let replayed = try await store.createTask(
      repeated,
      event: creationEvent(at: repeated.createdAt)
    )

    XCTAssertFalse(created.reusedExistingTask)
    XCTAssertTrue(replayed.reusedExistingTask)
    XCTAssertEqual(replayed.task.id, first.id)
    let events = try await store.events(taskID: first.id)
    XCTAssertEqual(events.map(\.kind), [.taskCreated])

    let changed = try makeServiceTask(
      id: "tsk-idempotent-conflict",
      projectID: project.id,
      date: first.createdAt.addingTimeInterval(20),
      clientRequestID: "request-same",
      prompt: "A different request must not reuse the first task.",
      permissionMode: .readOnly
    )
    do {
      _ = try await store.createTask(changed, event: creationEvent(at: changed.createdAt))
      XCTFail("Expected an idempotency conflict")
    } catch {
      XCTAssertEqual(
        error as? ServiceStoreError,
        .idempotencyConflict(source: .chatGPT, clientRequestID: "request-same")
      )
    }
  }

  func testInvalidTaskTransitionRollsBackStateAndEvent() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(
      id: "prj-transition",
      rootURL: fixture.firstProjectURL
    )
    try await store.insertProject(project)
    let task = try makeServiceTask(id: "tsk-transition", projectID: project.id)
    _ = try await store.createTask(task, event: creationEvent(at: task.createdAt))
    let invalidState = try ServiceTaskState(
      codexThreadID: "thr-too-early",
      codexTurnID: "turn-too-early",
      status: .running
    )
    let invalidDate = task.updatedAt.addingTimeInterval(1)
    let invalid = try task.replacingState(invalidState, updatedAt: invalidDate)

    do {
      try await store.updateTask(
        invalid,
        event: ServiceTaskEventDraft(
          kind: .executionStarted,
          summary: "This transition must be rolled back.",
          createdAt: invalidDate
        )
      )
      XCTFail("Expected an invalid task transition")
    } catch {
      XCTAssertEqual(
        error as? ServiceStoreError,
        .invalidTaskTransition(from: .awaitingLocalApproval, to: .running)
      )
    }

    let stored = try await store.task(id: task.id)
    let events = try await store.events(taskID: task.id)
    XCTAssertEqual(stored, task)
    XCTAssertEqual(events.map(\.kind), [.taskCreated])
  }

  func testEventInsertFailureRollsBackTheTaskStateUpdate() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(
      id: "prj-transaction-rollback",
      rootURL: fixture.firstProjectURL
    )
    try await store.insertProject(project)
    let task = try makeServiceTask(
      id: "tsk-transaction-rollback",
      projectID: project.id
    )
    _ = try await store.createTask(task, event: creationEvent(at: task.createdAt))
    let externalDatabase = try DatabaseQueue(path: fixture.databasePath)
    try await externalDatabase.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER reject_service_test_event
          BEFORE INSERT ON bridge_service_task_events
          BEGIN
            SELECT RAISE(ABORT, 'service test event rejected');
          END;
          """
      )
    }
    let updateDate = task.updatedAt.addingTimeInterval(1)
    let starting = try task.replacingState(
      ServiceTaskState(status: .starting),
      updatedAt: updateDate
    )

    do {
      try await store.updateTask(
        starting,
        event: ServiceTaskEventDraft(
          kind: .taskApproved,
          summary: "This event is deliberately rejected by SQLite.",
          createdAt: updateDate
        )
      )
      XCTFail("Expected the event trigger to reject the transaction")
    } catch {
      XCTAssertEqual(error as? ServiceStoreError, .storageFailure)
    }

    let stored = try await store.task(id: task.id)
    let events = try await store.events(taskID: task.id)
    XCTAssertEqual(stored, task)
    XCTAssertEqual(events.map(\.kind), [.taskCreated])
  }

  func testRestartMarksInFlightTaskUnknownAndPreservesWriteGate() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(
      id: "prj-recovery",
      rootURL: fixture.firstProjectURL
    )
    try await store.insertProject(project)
    let running = try makeServiceTask(
      id: "tsk-running-before-restart",
      projectID: project.id,
      status: .running,
      supervisorStatus: .running,
      supervisorModel: "supervisor-model",
      supervisorEffort: "medium"
    )
    _ = try await store.createTask(running, event: creationEvent(at: running.createdAt))
    let recoveryDate = running.updatedAt.addingTimeInterval(10)

    let recovered = try await store.markIncompleteTasksUnknown(at: recoveryDate)

    XCTAssertEqual(recovered.map(\.state.status), [.unknown])
    XCTAssertEqual(recovered.first?.state.supervisorStatus, .degraded)
    let recoveryEvents = try await store.events(taskID: running.id)
    XCTAssertEqual(
      recoveryEvents.map(\.kind),
      [.taskCreated, .taskMarkedUnknown]
    )
    let blocked = try makeServiceTask(
      id: "tsk-blocked-by-unknown",
      projectID: project.id,
      date: recoveryDate.addingTimeInterval(1)
    )
    do {
      _ = try await store.createTask(blocked, event: creationEvent(at: blocked.createdAt))
      XCTFail("Expected the unknown write task to retain the project write slot")
    } catch {
      XCTAssertEqual(error as? ServiceStoreError, .activeWriteTaskExists(project.id))
    }

    let recoveredValue = try await store.task(id: running.id)
    let recoveredTask = try XCTUnwrap(recoveredValue)
    let interruptedDate = recoveryDate.addingTimeInterval(2)
    let interruptedState = try ServiceTaskState(
      status: .interrupted,
      supervisorStatus: .degraded
    )
    let interrupted = try recoveredTask.replacingState(
      interruptedState,
      updatedAt: interruptedDate
    )
    try await store.updateTask(
      interrupted,
      event: ServiceTaskEventDraft(
        kind: .taskInterrupted,
        summary: "The local user resolved the unknown task as interrupted.",
        createdAt: interruptedDate
      )
    )

    let replacement = try makeServiceTask(
      id: "tsk-after-interruption",
      projectID: project.id,
      date: interruptedDate.addingTimeInterval(1)
    )
    let replacementResult = try await store.createTask(
      replacement,
      event: creationEvent(at: replacement.createdAt)
    )
    XCTAssertEqual(replacementResult.task.id, replacement.id)
  }

  func testProjectPolicyAndSettingsPersistWithoutASecondStore() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let clock = ServiceCoreTestClock()
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let projects = ServiceProjectService(
      store: store,
      makeProjectID: { ProjectID(rawValue: "prj-policy") },
      now: clock.next
    )
    let settings = ServiceSettings(store: store, now: clock.next)
    let project = try await projects.register(
      name: "Policy project",
      rootURL: fixture.firstProjectURL
    )
    let policy = ProjectAccessPolicy(
      read: .allowed,
      write: .allowed,
      network: .requiresLocalApproval
    )
    _ = try await projects.updateAccessPolicy(policy, projectID: project.id)
    let defaultExposure = try await settings.exposureMode()
    XCTAssertEqual(defaultExposure, .readOnly)
    try await settings.setExposureMode(.full)
    try await settings.set("codex-model", for: .defaultExecutionModel)

    let reopened = try SimpleServiceStore(path: fixture.databasePath)
    let reopenedSettings = ServiceSettings(store: reopened)
    let storedProject = try await reopened.project(id: project.id)

    let reopenedExposure = try await reopenedSettings.exposureMode()
    let reopenedExecutionModel = try await reopenedSettings.string(
      for: .defaultExecutionModel
    )
    XCTAssertEqual(storedProject?.accessPolicy, policy)
    XCTAssertEqual(storedProject?.root, project.root)
    XCTAssertEqual(reopenedExposure, .full)
    XCTAssertEqual(reopenedExecutionModel, "codex-model")
  }

  func testSupervisorEnabledDefaultsTrueAndPersistsToggle() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let settings = ServiceSettings(store: store)

    let initial = try await settings.isSupervisorEnabled()
    XCTAssertEqual(initial, true)

    try await settings.setSupervisorEnabled(false)
    let reopened = try SimpleServiceStore(path: fixture.databasePath)
    let reopenedSettings = ServiceSettings(store: reopened)
    let disabled = try await reopenedSettings.isSupervisorEnabled()
    XCTAssertEqual(disabled, false)

    try await reopenedSettings.setSupervisorEnabled(true)
    let reenabled = try await reopenedSettings.isSupervisorEnabled()
    XCTAssertEqual(reenabled, true)
  }
}
