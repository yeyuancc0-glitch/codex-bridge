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
    let (fixture, store, tasks) = try makeFixture()
    defer { fixture.remove() }
    let project = try makeServiceProject(id: "prj-messages", rootURL: fixture.firstProjectURL)
    try await store.insertProject(project)
    let task = try makeServiceTask(
      id: "tsk-messages",
      projectID: project.id,
      status: .running
    )
    try await store.createTask(task, event: creationEvent(at: task.createdAt))

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
}
