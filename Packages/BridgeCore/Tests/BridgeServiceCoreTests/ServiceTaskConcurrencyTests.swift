import BridgeDomain
import BridgeServiceCore
import XCTest

final class ServiceTaskConcurrencyTests: XCTestCase {
  func testConcurrentEquivalentTaskIDsConvergeAcrossConnections() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let first = try SimpleServiceStore(path: fixture.databasePath)
    let second = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(
      id: "prj-concurrent-replay",
      rootURL: fixture.firstProjectURL
    )
    try await first.insertProject(project)
    let task = try makeServiceTask(
      id: "tsk-concurrent-replay",
      projectID: project.id,
      permissionMode: .readOnly
    )

    async let firstResult = first.createTask(task, event: creationEvent(at: task.createdAt))
    async let secondResult = second.createTask(task, event: creationEvent(at: task.createdAt))
    let results = try await [firstResult, secondResult]

    let events = try await first.events(taskID: task.id)
    XCTAssertEqual(results.map(\.task.id), [task.id, task.id])
    XCTAssertEqual(results.filter { $0.reusedExistingTask }.count, 1)
    XCTAssertEqual(events.count, 1)
  }

  func testConcurrentWorkspaceWriteSubmissionsAllowExactlyOneTask() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let first = try SimpleServiceStore(path: fixture.databasePath)
    let project = try makeServiceProject(
      id: "prj-concurrent-write",
      rootURL: fixture.firstProjectURL
    )
    try await first.insertProject(project)
    let stores = try (0..<8).map { _ in try SimpleServiceStore(path: fixture.databasePath) }

    let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
      for (index, store) in stores.enumerated() {
        group.addTask {
          let date = Date(timeIntervalSince1970: 1_800_001_000 + Double(index))
          let task = try makeServiceTask(
            id: "tsk-concurrent-write-\(index)",
            projectID: project.id,
            date: date
          )
          do {
            _ = try await store.createTask(task, event: creationEvent(at: date))
            return true
          } catch ServiceStoreError.activeWriteTaskExists(project.id) {
            return false
          }
        }
      }

      var results: [Bool] = []
      for try await result in group {
        results.append(result)
      }
      return results
    }

    XCTAssertEqual(accepted.filter { $0 }.count, 1)
    XCTAssertEqual(accepted.filter { !$0 }.count, 7)
    let tasks = try await first.tasks(projectID: project.id)
    XCTAssertEqual(tasks.count, 1)
    XCTAssertEqual(tasks.first?.permissionMode, .workspaceWrite)
  }

  func testReadOnlyTasksShareAProjectWhileWriteTasksRemainProjectScoped() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let firstProject = try makeServiceProject(
      id: "prj-first-concurrency",
      rootURL: fixture.firstProjectURL
    )
    let secondProject = try makeServiceProject(
      id: "prj-second-concurrency",
      rootURL: fixture.secondProjectURL
    )
    try await store.insertProject(firstProject)
    try await store.insertProject(secondProject)

    for index in 0..<3 {
      let date = Date(timeIntervalSince1970: 1_800_002_000 + Double(index))
      let task = try makeServiceTask(
        id: "tsk-read-only-\(index)",
        projectID: firstProject.id,
        date: date,
        permissionMode: .readOnly
      )
      _ = try await store.createTask(task, event: creationEvent(at: date))
    }
    let firstWriteDate = Date(timeIntervalSince1970: 1_800_002_100)
    let firstWrite = try makeServiceTask(
      id: "tsk-first-project-write",
      projectID: firstProject.id,
      date: firstWriteDate
    )
    _ = try await store.createTask(firstWrite, event: creationEvent(at: firstWriteDate))
    let secondWriteDate = Date(timeIntervalSince1970: 1_800_002_101)
    let secondWrite = try makeServiceTask(
      id: "tsk-second-project-write",
      projectID: secondProject.id,
      date: secondWriteDate
    )
    _ = try await store.createTask(secondWrite, event: creationEvent(at: secondWriteDate))

    let firstTasks = try await store.tasks(projectID: firstProject.id)
    let secondTasks = try await store.tasks(projectID: secondProject.id)
    XCTAssertEqual(firstTasks.count, 4)
    XCTAssertEqual(firstTasks.filter { $0.permissionMode == .readOnly }.count, 3)
    XCTAssertEqual(firstTasks.filter { $0.permissionMode == .workspaceWrite }.count, 1)
    XCTAssertEqual(secondTasks.map(\.id), [secondWrite.id])
  }
}
