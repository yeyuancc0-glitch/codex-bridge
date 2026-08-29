import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import XCTest

final class ServiceTaskMessageAndDeleteTests: XCTestCase {
  private func makeFixture() throws -> (ServiceCoreFixture, SimpleServiceStore, ServiceTaskManager)
  {
    let fixture = try ServiceCoreFixture()
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let tasks = ServiceTaskManager(store: store)
    return (fixture, store, tasks)
  }

  func testMessageUpsertDeduplicatesByKeyAndPaginates() async throws {
    let (fixture, store, _) = try makeFixture()
    defer { fixture.remove() }
    let project = try makeServiceProject(id: "prj-messages", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    let task = try makeServiceTask(
      id: "tsk-messages",
      projectID: project.id,
      status: .running
    )
    _ = try await store.createTask(task, event: creationEvent(at: task.createdAt))

    let prompt = try ServiceTaskMessageDraft(
      key: "user:1",
      role: .user,
      content: "Please refactor the parser.",
      createdAt: Date(timeIntervalSince1970: 1_800_000_200)
    )
    let first = try await store.upsertTaskMessage(prompt, taskID: task.id)
    XCTAssertEqual(first.key, "user:1")
    XCTAssertEqual(first.role, .user)

    let updated = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: "user:1",
        role: .user,
        content: "Please refactor the parser and its tests.",
        createdAt: Date(timeIntervalSince1970: 1_800_000_300)
      ),
      taskID: task.id
    )
    XCTAssertEqual(updated.id, first.id)
    XCTAssertEqual(updated.createdAt, first.createdAt)
    XCTAssertGreaterThan(updated.updatedAt, first.updatedAt)

    let agent = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: "agent:item-1",
        role: .agent,
        content: "I will inspect the parser module.",
        createdAt: Date(timeIntervalSince1970: 1_800_000_400)
      ),
      taskID: task.id
    )
    let agentTwo = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: "agent:item-2",
        role: .agent,
        content: "Done.",
        createdAt: Date(timeIntervalSince1970: 1_800_000_500)
      ),
      taskID: task.id
    )

    let all = try await store.taskMessages(taskID: task.id, limit: 100)
    XCTAssertEqual(all.map(\.key), ["user:1", "agent:item-1", "agent:item-2"])
    XCTAssertEqual(all[0].content, "Please refactor the parser and its tests.")

    let page = try await store.taskMessages(
      taskID: task.id,
      beforeMessageID: agentTwo.id,
      limit: 10
    )
    XCTAssertEqual(page.map(\.key), ["user:1", "agent:item-1"])

    let agentOnly = try await store.taskMessages(
      taskID: task.id, beforeMessageID: agent.id, limit: 1)
    XCTAssertEqual(agentOnly.map(\.key), ["user:1"])
  }

  func testRecentActivityUsesLastUpdateInsteadOfMessageCreationOrder() async throws {
    let (fixture, store, _) = try makeFixture()
    defer { fixture.remove() }
    let project = try makeServiceProject(id: "prj-activity-order", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    let task = try makeServiceTask(
      id: "tsk-activity-order",
      projectID: project.id,
      status: .running
    )
    _ = try await store.createTask(task, event: creationEvent(at: task.createdAt))

    let early = try ServiceTaskMessageDraft(
      key: "reasoning:early",
      role: .agent,
      content: "first",
      createdAt: Date(timeIntervalSince1970: 1_800_000_200),
      kind: .reasoning
    )
    _ = try await store.upsertTaskMessage(early, taskID: task.id)
    for index in 0..<12 {
      _ = try await store.upsertTaskMessage(
        ServiceTaskMessageDraft(
          key: "agent:\(index)",
          role: .agent,
          content: "later \(index)",
          createdAt: Date(timeIntervalSince1970: 1_800_000_300 + Double(index))
        ),
        taskID: task.id
      )
    }
    _ = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: early.key,
        role: early.role,
        content: "updated last",
        createdAt: early.createdAt,
        kind: early.kind,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_500)
      ),
      taskID: task.id
    )

    let activity = try await store.recentTaskMessageActivity(taskID: task.id, limit: 8)
    let refreshedTaskValue = try await store.task(id: task.id)
    let refreshedTask = try XCTUnwrap(refreshedTaskValue)
    XCTAssertEqual(activity.last?.key, early.key)
    XCTAssertEqual(activity.last?.content, "updated last")
    XCTAssertEqual(activity.last?.createdAt, early.createdAt)
    XCTAssertEqual(activity.last?.updatedAt, Date(timeIntervalSince1970: 1_800_000_500))
    XCTAssertEqual(refreshedTask.updatedAt, Date(timeIntervalSince1970: 1_800_000_500))

    _ = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: "agent:older-replay",
        role: .agent,
        content: "older replay",
        createdAt: Date(timeIntervalSince1970: 1_800_000_250)
      ),
      taskID: task.id
    )
    let afterReplayValue = try await store.task(id: task.id)
    let afterReplay = try XCTUnwrap(afterReplayValue)
    XCTAssertEqual(
      afterReplay.updatedAt,
      Date(timeIntervalSince1970: 1_800_000_500)
    )
  }

  func testUpsertMessageRequiresExistingTask() async throws {
    let (fixture, store, _) = try makeFixture()
    defer { fixture.remove() }
    let project = try makeServiceProject(id: "prj-missing-task", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    do {
      _ = try await store.upsertTaskMessage(
        ServiceTaskMessageDraft(
          key: "user:1",
          role: .user,
          content: "hello",
          createdAt: Date(timeIntervalSince1970: 1_800_000_200)
        ),
        taskID: TaskID(rawValue: "tsk-missing")
      )
      XCTFail("Expected unknownTask error")
    } catch let error as ServiceStoreError {
      guard case .unknownTask = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRemoveTaskCascadesEventsAndMessages() async throws {
    let (fixture, store, tasks) = try makeFixture()
    defer { fixture.remove() }
    let project = try makeServiceProject(id: "prj-delete", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)

    let created = try await tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        clientRequestID: "request-delete",
        prompt: "Delete me later.",
        executionModel: "codex-model",
        executionEffort: "high",
        permissionMode: .workspaceWrite
      )
    )
    let taskID = created.task.id
    _ = try await tasks.begin(taskID: taskID)
    _ = try await tasks.markExecutionStarted(
      taskID: taskID,
      threadID: "thr-delete",
      turnID: "turn-delete"
    )
    _ = try await tasks.complete(
      taskID: taskID,
      resultSummary: "Completed.",
      changedFiles: []
    )
    _ = try await store.upsertTaskMessage(
      ServiceTaskMessageDraft(
        key: "user:1",
        role: .user,
        content: "hello",
        createdAt: Date(timeIntervalSince1970: 1_800_000_200)
      ),
      taskID: taskID
    )
    let events = try await store.events(taskID: taskID)
    XCTAssertFalse(events.isEmpty)

    try await tasks.remove(taskID: taskID)

    let storedTask = try await store.task(id: taskID)
    let storedEvents = try await store.events(taskID: taskID)
    let storedMessages = try await store.taskMessages(taskID: taskID)
    XCTAssertNil(storedTask)
    XCTAssertTrue(storedEvents.isEmpty)
    XCTAssertTrue(storedMessages.isEmpty)
  }

  func testRemoveTaskRejectsActiveTask() async throws {
    let (fixture, store, tasks) = try makeFixture()
    defer { fixture.remove() }
    let project = try makeServiceProject(id: "prj-delete-active", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    let created = try await tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        clientRequestID: "request-delete-active",
        prompt: "Active task.",
        executionModel: "codex-model",
        executionEffort: "high",
        permissionMode: .workspaceWrite
      )
    )
    _ = try await tasks.begin(taskID: created.task.id)

    do {
      try await tasks.remove(taskID: created.task.id)
      XCTFail("Expected invalidArgument for active task")
    } catch let error as ServiceStoreError {
      guard case .invalidArgument("task.removeActive") = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let storedTask = try await store.task(id: created.task.id)
    XCTAssertNotNil(storedTask)
  }

  func testRemoveTaskRejectsUnknownTask() async throws {
    let (fixture, store, tasks) = try makeFixture()
    defer { fixture.remove() }
    do {
      try await tasks.remove(taskID: TaskID(rawValue: "tsk-unknown"))
      XCTFail("Expected unknownTask error")
    } catch let error as ServiceStoreError {
      guard case .unknownTask = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    _ = store
  }

  func testRemoveProjectChecksAllTasksAndCascadesTerminalData() async throws {
    let (fixture, store, tasks) = try makeFixture()
    defer { fixture.remove() }
    let project = try makeServiceProject(id: "prj-remove-all", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)

    let active = try makeServiceTask(
      id: "tsk-remove-active-outside-page",
      projectID: project.id,
      date: Date(timeIntervalSince1970: 1_700_000_100),
      status: .running,
      permissionMode: .readOnly
    )
    _ = try await store.createTask(active, event: creationEvent(at: active.createdAt))

    var terminalIDs: [TaskID] = []
    for index in 0...500 {
      let terminal = try makeServiceTask(
        id: "tsk-remove-terminal-" + String(index),
        projectID: project.id,
        date: Date(timeIntervalSince1970: 1_700_001_000 + Double(index)),
        status: .completed,
        permissionMode: .readOnly
      )
      _ = try await store.createTask(terminal, event: creationEvent(at: terminal.createdAt))
      if index == 0 || index == 500 {
        _ = try await store.upsertTaskMessage(
          ServiceTaskMessageDraft(
            key: "agent:terminal-" + String(index),
            role: .agent,
            content: "Terminal task " + String(index) + ".",
            createdAt: terminal.createdAt
          ),
          taskID: terminal.id
        )
      }
      terminalIDs.append(terminal.id)
    }

    do {
      try await store.removeProject(id: project.id)
      XCTFail("Expected the active task to block project removal")
    } catch let error as ServiceStoreError {
      XCTAssertEqual(error, .invalidArgument("project.activeTasks"))
    }
    let activeBeforeRemoval = try await store.task(id: active.id)
    let lastTerminalBeforeRemoval = try await store.task(id: terminalIDs.last!)
    XCTAssertNotNil(activeBeforeRemoval)
    XCTAssertNotNil(lastTerminalBeforeRemoval)

    _ = try await tasks.interrupt(
      taskID: active.id,
      summary: "The active task was stopped before project removal."
    )
    try await store.removeProject(id: project.id)

    let removedProject = try await store.project(id: project.id)
    let removedActive = try await store.task(id: active.id)
    let removedFirstTerminal = try await store.task(id: terminalIDs.first!)
    let removedLastTerminal = try await store.task(id: terminalIDs.last!)
    XCTAssertNil(removedProject)
    XCTAssertNil(removedActive)
    XCTAssertNil(removedFirstTerminal)
    XCTAssertNil(removedLastTerminal)
    let terminalEvents = try await store.events(taskID: terminalIDs.first!)
    let terminalMessages = try await store.taskMessages(taskID: terminalIDs.last!)
    XCTAssertTrue(terminalEvents.isEmpty)
    XCTAssertTrue(terminalMessages.isEmpty)
  }
}
