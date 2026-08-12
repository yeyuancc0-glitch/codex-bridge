import BridgeDomain
import BridgeExecution
import BridgePersistence
import BridgeProjects
import BridgeReporting
import BridgeSecurity
import Foundation
import GRDB
import XCTest

@testable import BridgeRepositories

final class ApplicationRepositoryTests: XCTestCase {
  func testProjectConfigurationAndBindingSurviveRestartInSharedDatabase() async throws {
    let fixture = try makeFixture()
    let eventStore = try EventStore(path: fixture.databasePath)
    let first = try ApplicationRepository(path: fixture.databasePath)
    let project = try makeProject(fixture: fixture)
    let taskID = TaskID(rawValue: "tsk-shared-database")
    try await eventStore.append(
      TaskEventEnvelope(
        taskID: taskID,
        sequence: 1,
        schemaVersion: 1,
        source: "test",
        kind: "task.created",
        severity: "info",
        payload: Data("{}".utf8),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      expectedLastSequence: 0
    )
    try await first.insert(project)
    try await first.insert(project)
    let boundAt = Date(timeIntervalSince1970: 1_700_000_123)
    try await first.storeBinding(
      ThreadProjectBindingRecord(
        threadID: "thr-persisted",
        projectID: project.id,
        root: project.worktreeRoots[0],
        boundAt: boundAt
      )
    )

    let reopenedEvents = try EventStore(path: fixture.databasePath)
    let reopened = try ApplicationRepository(path: fixture.databasePath)
    let stored = try await reopened.project(id: project.id)
    let binding = try await reopened.storedBinding(for: "thr-persisted")

    XCTAssertEqual(stored, project)
    XCTAssertEqual(stored?.primaryRoot.identity, project.primaryRoot.identity)
    XCTAssertEqual(stored?.repositoryRoot.identity, project.repositoryRoot.identity)
    XCTAssertEqual(stored?.worktreeRoots, project.worktreeRoots)
    XCTAssertEqual(stored?.accessPolicy, project.accessPolicy)
    XCTAssertEqual(stored?.verificationCommands, project.verificationCommands)
    XCTAssertEqual(binding?.projectID, project.id)
    XCTAssertEqual(binding?.root, project.worktreeRoots[0])
    XCTAssertEqual(binding?.boundAt, boundAt)
    let lastSequence = try await reopenedEvents.lastEventSequence(for: taskID)
    XCTAssertEqual(lastSequence, 1)
  }

  func testRootAndThreadUniquenessAreTransactionalAndIdempotent() async throws {
    let fixture = try makeFixture()
    let repository = try ApplicationRepository(path: fixture.databasePath)
    let first = try makeProject(fixture: fixture, id: "prj-first")
    try await repository.insert(first)

    let duplicate = RegisteredProject(
      id: ProjectID(rawValue: "prj-duplicate-root"),
      name: "Duplicate",
      primaryRoot: first.primaryRoot,
      repositoryRoot: first.repositoryRoot,
      accessPolicy: .init(),
      verificationCommands: [],
      forbiddenPatterns: [],
      createdAt: first.createdAt.addingTimeInterval(1)
    )
    do {
      try await repository.insert(duplicate)
      XCTFail("Expected the duplicate root to be rejected")
    } catch {
      XCTAssertEqual(error as? ProjectRegistryError, .duplicateRoot)
    }
    let missingDuplicate = try await repository.project(id: duplicate.id)
    XCTAssertNil(missingDuplicate)

    let worktree = first.worktreeRoots[0]
    try await repository.addWorktree(worktree, to: first.id)
    let updatedProject = try await repository.project(id: first.id)
    XCTAssertEqual(updatedProject?.worktreeRoots, [worktree])

    let binding = ThreadProjectBindingRecord(
      threadID: "thr-one-owner",
      projectID: first.id,
      root: first.primaryRoot,
      boundAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try await repository.storeBinding(binding)
    try await repository.storeBinding(
      ThreadProjectBindingRecord(
        threadID: binding.threadID,
        projectID: binding.projectID,
        root: binding.root,
        boundAt: binding.boundAt.addingTimeInterval(10)
      )
    )

    do {
      try await repository.storeBinding(
        ThreadProjectBindingRecord(
          threadID: binding.threadID,
          projectID: binding.projectID,
          root: worktree,
          boundAt: binding.boundAt
        )
      )
      XCTFail("Expected a conflicting binding to be rejected")
    } catch {
      XCTAssertEqual(error as? ProjectExecutionError, .threadAlreadyBound)
    }
    let storedBinding = try await repository.storedBinding(for: binding.threadID)
    XCTAssertEqual(storedBinding, binding)

    do {
      try await repository.storeBinding(
        ThreadProjectBindingRecord(
          threadID: "thr-unregistered-root",
          projectID: first.id,
          root: first.repositoryRoot,
          boundAt: binding.boundAt
        )
      )
      XCTFail("Expected a non-execution root to be rejected")
    } catch {
      XCTAssertEqual(error as? ApplicationRepositoryError, .unregisteredBindingRoot)
    }
  }

  func testConcurrentDatabaseInstancesEnforceOneRootOwner() async throws {
    let fixture = try makeFixture()
    let firstRepository = try ApplicationRepository(path: fixture.databasePath)
    let secondRepository = try ApplicationRepository(path: fixture.databasePath)
    let firstProject = try makeProject(fixture: fixture, id: "prj-concurrent-first")
    let secondProject = RegisteredProject(
      id: ProjectID(rawValue: "prj-concurrent-second"),
      name: "Second",
      primaryRoot: firstProject.primaryRoot,
      repositoryRoot: firstProject.repositoryRoot,
      worktreeRoots: firstProject.worktreeRoots,
      accessPolicy: firstProject.accessPolicy,
      verificationCommands: firstProject.verificationCommands,
      forbiddenPatterns: firstProject.forbiddenPatterns,
      createdAt: firstProject.createdAt.addingTimeInterval(1)
    )

    let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      group.addTask {
        do {
          try await firstRepository.insert(firstProject)
          return true
        } catch {
          return false
        }
      }
      group.addTask {
        do {
          try await secondRepository.insert(secondProject)
          return true
        } catch {
          return false
        }
      }
      var results: [Bool] = []
      for await result in group { results.append(result) }
      return results
    }

    XCTAssertEqual(outcomes.filter { $0 }.count, 1)
    let projects = try await firstRepository.allProjects()
    XCTAssertEqual(projects.count, 1)
  }

  func testFinalReportIsBoundedIdempotentAndSurvivesRestart() async throws {
    let fixture = try makeFixture()
    let first = try ApplicationRepository(path: fixture.databasePath)
    let taskID = TaskID(rawValue: "tsk-final-report")
    let document = try makeReport(taskID: taskID.rawValue, project: "Codex Bridge")
    let storedAt = Date(timeIntervalSince1970: 1_700_000_300)

    let initialMetadata = try await first.storeFinalReport(document, storedAt: storedAt)
    let repeatedMetadata = try await first.storeFinalReport(
      document,
      storedAt: storedAt.addingTimeInterval(50)
    )
    XCTAssertEqual(repeatedMetadata, initialMetadata)

    let conflicting = try makeReport(taskID: taskID.rawValue, project: "Changed Project")
    do {
      _ = try await first.storeFinalReport(conflicting, storedAt: storedAt)
      XCTFail("Expected an immutable final-report conflict")
    } catch {
      XCTAssertEqual(error as? ApplicationRepositoryError, .finalReportConflict(taskID))
    }

    let reopened = try ApplicationRepository(path: fixture.databasePath)
    let stored = try await reopened.finalReport(for: taskID)
    XCTAssertEqual(stored?.metadata, initialMetadata)
    XCTAssertEqual(stored?.json, document.json)
    XCTAssertFalse(String(decoding: document.json, as: UTF8.self).contains("stdout"))
    XCTAssertFalse(String(decoding: document.json, as: UTF8.self).contains("raw_output"))
  }

  func testUnknownRepositoryMigrationAndSchemaVersionAreRejected() throws {
    let unknownMigration = try makeFixture()
    _ = try ApplicationRepository(path: unknownMigration.databasePath)
    let unknownDatabase = try DatabaseQueue(path: unknownMigration.databasePath)
    try unknownDatabase.write { db in
      try db.execute(
        sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
        arguments: ["BridgeRepositories.future"]
      )
    }
    XCTAssertThrowsError(try ApplicationRepository(path: unknownMigration.databasePath)) { error in
      XCTAssertEqual(
        error as? ApplicationRepositoryError,
        .unknownMigration("BridgeRepositories.future")
      )
    }

    let futureSchema = try makeFixture()
    _ = try ApplicationRepository(path: futureSchema.databasePath)
    let futureDatabase = try DatabaseQueue(path: futureSchema.databasePath)
    try futureDatabase.write { db in
      try db.execute(
        sql: "UPDATE bridge_repository_meta SET schema_version = 99 WHERE singleton = 1"
      )
    }
    XCTAssertThrowsError(try ApplicationRepository(path: futureSchema.databasePath)) { error in
      XCTAssertEqual(error as? ApplicationRepositoryError, .unsupportedSchemaVersion(99))
    }
  }

  func testCorruptConfigurationAndReportRowsAreRejectedOnOpen() async throws {
    let corruptProject = try makeFixture()
    let projectRepository = try ApplicationRepository(path: corruptProject.databasePath)
    let project = try makeProject(fixture: corruptProject)
    try await projectRepository.insert(project)
    let projectDatabase = try DatabaseQueue(path: corruptProject.databasePath)
    try await projectDatabase.write { db in
      try db.execute(
        sql: "UPDATE bridge_repository_projects SET configuration_json = ? WHERE project_id = ?",
        arguments: [Data("{}".utf8), project.id.rawValue]
      )
    }
    XCTAssertThrowsError(try ApplicationRepository(path: corruptProject.databasePath)) { error in
      XCTAssertEqual(
        error as? ApplicationRepositoryError,
        .corruptRecord("project_configuration.checksum")
      )
    }

    let corruptReport = try makeFixture()
    let reportRepository = try ApplicationRepository(path: corruptReport.databasePath)
    let taskID = TaskID(rawValue: "tsk-corrupt-report")
    let document = try makeReport(taskID: taskID.rawValue, project: "Bridge")
    _ = try await reportRepository.storeFinalReport(
      document,
      storedAt: Date(timeIntervalSince1970: 1_700_000_500)
    )
    let reportDatabase = try DatabaseQueue(path: corruptReport.databasePath)
    try await reportDatabase.write { db in
      try db.execute(
        sql:
          "UPDATE bridge_repository_final_reports SET project_name = 'tampered' WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
    }
    XCTAssertThrowsError(try ApplicationRepository(path: corruptReport.databasePath)) { error in
      XCTAssertEqual(
        error as? ApplicationRepositoryError,
        .corruptRecord("final_report.metadata")
      )
    }
  }

  private func makeProject(
    fixture: Fixture,
    id: String = "prj-persisted"
  ) throws -> RegisteredProject {
    let command = try VerificationCommand(
      executable: "/usr/bin/xcrun",
      arguments: ["swift", "test"]
    )
    return RegisteredProject(
      id: ProjectID(rawValue: id),
      name: "Codex Bridge",
      primaryRoot: try RegisteredRoot(capturing: fixture.projectURL),
      repositoryRoot: try RegisteredRoot(capturing: fixture.repositoryURL),
      worktreeRoots: [try RegisteredRoot(capturing: fixture.worktreeURL)],
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .requiresLocalApproval,
        network: .denied
      ),
      verificationCommands: [command],
      forbiddenPatterns: [try ForbiddenPathPattern("Generated/**")],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func makeReport(taskID: String, project: String) throws -> FinalReportDocument {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    return try ReportBuilder().build(
      from: FinalReportInput(
        taskID: taskID,
        status: .completed,
        project: project,
        appServer: AppServerEvidence(
          threadID: "thr-report",
          model: "gpt-test",
          effort: "high",
          terminalState: .completed,
          commands: [
            AppServerCommandEvidence(
              sequence: 1,
              executable: "/usr/bin/xcrun",
              arguments: ["swift", "test"],
              exitCode: 0
            )
          ],
          startedAt: startedAt,
          completedAt: startedAt.addingTimeInterval(60)
        ),
        git: GitEvidence(
          baselineCaptured: true,
          finalStateCaptured: true,
          dirtyAtStart: false,
          changedFiles: [
            GitChangedFileEvidence(relativePath: "Sources/App.swift", change: .modified)
          ],
          diffStat: "1 file changed"
        ),
        verification: [
          VerificationEvidence(
            id: "swift-test",
            name: "swift test",
            required: true,
            status: .passed,
            exitCode: 0
          )
        ],
        supervisor: SupervisorEvidence(
          model: "luna-test",
          effort: "medium",
          checks: 2,
          steers: 0,
          finalDecision: .finalAccept
        ),
        policy: PolicyEvidence(evaluationCompleted: true)
      )
    )
  }

  private func makeFixture() throws -> Fixture {
    let scratch = FileManager.default.temporaryDirectory
      .appending(
        path: "bridge-repositories-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let repository = scratch.appending(path: "repository", directoryHint: .isDirectory)
    let project = repository.appending(path: "Sources", directoryHint: .isDirectory)
    let worktree = scratch.appending(path: "worktree", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
    return Fixture(
      databasePath: scratch.appending(path: "bridge.sqlite").path,
      repositoryURL: repository,
      projectURL: project,
      worktreeURL: worktree
    )
  }
}

private struct Fixture {
  let databasePath: String
  let repositoryURL: URL
  let projectURL: URL
  let worktreeURL: URL
}
