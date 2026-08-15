import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgeSecurity
import Foundation
import XCTest

@testable import BridgePipeline

final class PipelinePreflightStoreTests: XCTestCase {
  func testPrivateStoreSurvivesRestartWithExactStartedTurnBinding() async throws {
    let fixture = try makeFixture()
    let store = try PipelinePreflightStore(path: fixture.storeURL.path)
    try await store.storeBaseline(
      context: fixture.preStart,
      baseline: fixture.baseline,
      at: Date(timeIntervalSince1970: 20)
    )
    try await store.recordStartedTurn(fixture.started)

    let restarted = try PipelinePreflightStore(path: fixture.storeURL.path)
    let record = try await restarted.startedRecord(
      taskID: fixture.preStart.taskID,
      binding: fixture.started.binding
    )

    XCTAssertEqual(record.baseline, fixture.baseline)
    XCTAssertEqual(record.key.startIntentSequence, fixture.preStart.startIntentSequence)
    XCTAssertEqual(record.turnID, fixture.started.binding.turnID)
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.storeURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testStoreRejectsSymlinkAndMismatchedStartedBinding() async throws {
    let fixture = try makeFixture()
    let store = try PipelinePreflightStore(path: fixture.storeURL.path)
    try await store.storeBaseline(context: fixture.preStart, baseline: fixture.baseline)
    let mismatched = TaskPipelineStartedContext(
      preStart: fixture.preStart,
      binding: ExecutionBinding(
        threadID: fixture.started.binding.threadID,
        turnID: TurnID(rawValue: "turn-other"),
        turnGeneration: fixture.started.binding.turnGeneration + 1
      )
    )
    do {
      try await store.recordStartedTurn(mismatched)
      XCTFail("Expected binding mismatch")
    } catch {
      XCTAssertEqual(
        error as? PipelinePreflightStoreError,
        .conflict(fixture.preStart.taskID)
      )
    }

    let target = fixture.directory.appendingPathComponent("target.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: target.path
    )
    let symlink = fixture.directory.appendingPathComponent("symlink.json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    do {
      _ = try PipelinePreflightStore(path: symlink.path)
      XCTFail("Expected symlink rejection")
    } catch {
      XCTAssertEqual(error as? PipelinePreflightStoreError, .unavailable)
    }
  }

  func testTwoStoreInstancesReloadUnderGlobalLockWithoutLostUpdates() async throws {
    let fixture = try makeFixture()
    let first = try PipelinePreflightStore(path: fixture.storeURL.path)
    let second = try PipelinePreflightStore(path: fixture.storeURL.path)
    try await first.storeBaseline(context: fixture.preStart, baseline: fixture.baseline)
    let other = makeOtherContext(from: fixture)
    try await second.storeBaseline(context: other.preStart, baseline: other.baseline)

    let restarted = try PipelinePreflightStore(path: fixture.storeURL.path)
    let records = try await restarted.allRecords()

    XCTAssertEqual(records.map(\.key.taskID.rawValue), ["task-other", "task-preflight"])
  }

  func testRetentionDiscardIsNarrowRestartSafeAndIdempotent() async throws {
    let fixture = try makeFixture()
    let first = try PipelinePreflightStore(path: fixture.storeURL.path)
    let second = try PipelinePreflightStore(path: fixture.storeURL.path)
    try await first.storeBaseline(context: fixture.preStart, baseline: fixture.baseline)
    let other = makeOtherContext(from: fixture)
    try await second.storeBaseline(context: other.preStart, baseline: other.baseline)

    let removed = try await first.discardForRetention(taskID: fixture.preStart.taskID)
    XCTAssertEqual(removed, .removed)
    let restarted = try PipelinePreflightStore(path: fixture.storeURL.path)
    let restartedTaskIDs = try await restarted.allRecords().map(\.key.taskID.rawValue)
    XCTAssertEqual(restartedTaskIDs, ["task-other"])
    let repeated = try await second.discardForRetention(taskID: fixture.preStart.taskID)
    XCTAssertEqual(repeated, .alreadyAbsent)
    let secondTaskIDs = try await second.allRecords().map(\.key.taskID.rawValue)
    XCTAssertEqual(secondTaskIDs, ["task-other"])
  }

  func testRetentionDiscardRejectsInvalidTaskIdentityWithoutRewritingStore() async throws {
    let fixture = try makeFixture()
    let store = try PipelinePreflightStore(path: fixture.storeURL.path)
    try await store.storeBaseline(context: fixture.preStart, baseline: fixture.baseline)
    let original = try Data(contentsOf: fixture.storeURL)

    do {
      _ = try await store.discardForRetention(taskID: TaskID(rawValue: "bad\0task"))
      XCTFail("Expected invalid task identity")
    } catch {
      XCTAssertEqual(error as? PipelinePreflightStoreError, .invalidArgument("taskID"))
    }
    XCTAssertEqual(try Data(contentsOf: fixture.storeURL), original)
  }

  private struct Fixture {
    let directory: URL
    let storeURL: URL
    let preStart: TaskPipelinePreStartContext
    let started: TaskPipelineStartedContext
    let baseline: GitBaselineEvidence
  }

  private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-pipeline-preflight-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let root = try RegisteredRoot(capturing: directory)
    let submission = TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "preflight-store"),
      projectID: ProjectID(rawValue: "project-preflight"),
      thread: .new,
      execution: ExecutionOptions(
        model: "gpt-5",
        effort: "high",
        permissionMode: "read-only",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(enabled: true, model: "luna", effort: "medium"),
      contract: TaskContract(goal: "Persist baseline", acceptanceCriteria: ["Restart works"])
    )
    let preparation = PreparedTaskExecution(
      threadID: ThreadID(rawValue: "thread-preflight"),
      turnGeneration: 1,
      lockKeys: ["thread:thread-preflight", "worktree:project-preflight"]
    )
    let preStart = TaskPipelinePreStartContext(
      taskID: TaskID(rawValue: "task-preflight"),
      submission: submission,
      preparation: preparation,
      startIntentSequence: 4
    )
    let binding = ExecutionBinding(
      threadID: preparation.threadID,
      turnID: TurnID(rawValue: "turn-preflight"),
      turnGeneration: preparation.turnGeneration
    )
    return Fixture(
      directory: directory,
      storeURL: directory.appendingPathComponent("preflight.json"),
      preStart: preStart,
      started: TaskPipelineStartedContext(preStart: preStart, binding: binding),
      baseline: GitBaselineEvidence(
        projectIdentifier: submission.projectID.rawValue,
        canonicalRootPath: root.canonicalPath,
        rootIdentity: GitRootIdentity(device: root.identity.device, inode: root.identity.inode),
        capturedAt: Date(timeIntervalSince1970: 10),
        status: .notGitRepository,
        changeAttribution: .unavailableForNonGitProject
      )
    )
  }

  private func makeOtherContext(from fixture: Fixture) -> (
    preStart: TaskPipelinePreStartContext,
    baseline: GitBaselineEvidence
  ) {
    let submission = TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "preflight-other"),
      projectID: fixture.preStart.submission.projectID,
      thread: .new,
      execution: fixture.preStart.submission.execution,
      supervisor: fixture.preStart.submission.supervisor,
      contract: fixture.preStart.submission.contract
    )
    let preparation = PreparedTaskExecution(
      threadID: ThreadID(rawValue: "thread-other"),
      turnGeneration: 1,
      lockKeys: ["thread:thread-other", "worktree:project-preflight"]
    )
    return (
      TaskPipelinePreStartContext(
        taskID: TaskID(rawValue: "task-other"),
        submission: submission,
        preparation: preparation,
        startIntentSequence: 4
      ),
      GitBaselineEvidence(
        projectIdentifier: submission.projectID.rawValue,
        canonicalRootPath: fixture.baseline.canonicalRootPath,
        rootIdentity: fixture.baseline.rootIdentity,
        capturedAt: Date(timeIntervalSince1970: 11),
        status: .notGitRepository,
        changeAttribution: .unavailableForNonGitProject
      )
    )
  }
}
