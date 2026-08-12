import BridgeDomain
import Foundation
import XCTest

@testable import BridgePersistence

final class EventStoreTests: XCTestCase {
  func testConcurrentEquivalentSubmissionClaimsReturnOneTask() async throws {
    let store = try EventStore.inMemory()
    let key = IdempotencyKey(rawValue: "submission-1")

    let results = try await withThrowingTaskGroup(of: TaskID.self) { group in
      for index in 0..<24 {
        group.addTask {
          try await store.claimSubmission(
            origin: "chatgpt",
            key: key,
            requestFingerprint: "sha256:equivalent",
            taskID: TaskID(rawValue: "task-\(index)")
          )
        }
      }

      var taskIDs: [TaskID] = []
      for try await taskID in group {
        taskIDs.append(taskID)
      }
      return taskIDs
    }

    let uniqueTaskIDs = Set(results)
    XCTAssertEqual(uniqueTaskIDs.count, 1)
    let claimedTaskID = try XCTUnwrap(uniqueTaskIDs.first)
    let repeatedTaskID = try await store.claimSubmission(
      origin: "chatgpt",
      key: key,
      requestFingerprint: "sha256:equivalent",
      taskID: TaskID(rawValue: "ignored-on-retry")
    )
    XCTAssertEqual(repeatedTaskID, claimedTaskID)
  }

  func testSubmissionClaimRejectsFingerprintMismatch() async throws {
    let store = try EventStore.inMemory()
    let key = IdempotencyKey(rawValue: "submission-2")
    _ = try await store.claimSubmission(
      origin: "mcp",
      key: key,
      requestFingerprint: "sha256:first",
      taskID: TaskID(rawValue: "task-original")
    )

    do {
      _ = try await store.claimSubmission(
        origin: "mcp",
        key: key,
        requestFingerprint: "sha256:different",
        taskID: TaskID(rawValue: "task-replacement")
      )
      XCTFail("Expected an idempotency mismatch")
    } catch {
      XCTAssertEqual(
        error as? EventStoreError,
        .idempotencyMismatch(origin: "mcp", key: key)
      )
    }
  }

  func testClaimAndInitialEventsCommitAtomically() async throws {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "task-initialized")
    let events = [
      makeEvent(taskID: taskID, sequence: 1, kind: "task.submission"),
      makeEvent(taskID: taskID, sequence: 2, kind: "task.preparationStarted"),
    ]

    let claimed = try await store.claimSubmission(
      origin: "chatgpt",
      key: IdempotencyKey(rawValue: "atomic-initialization"),
      requestFingerprint: "sha256:atomic",
      taskID: taskID,
      initialEvents: events
    )

    XCTAssertEqual(claimed, taskID)
    let storedEvents = try await store.events(for: taskID)
    let lastSequence = try await store.lastEventSequence(for: taskID)
    XCTAssertEqual(storedEvents, events)
    XCTAssertEqual(lastSequence, 2)
  }

  func testExistingClaimDoesNotInstallCompetingInitialEvents() async throws {
    let store = try EventStore.inMemory()
    let winner = TaskID(rawValue: "task-winner")
    let loser = TaskID(rawValue: "task-loser")
    let key = IdempotencyKey(rawValue: "atomic-retry")
    _ = try await store.claimSubmission(
      origin: "chatgpt",
      key: key,
      requestFingerprint: "sha256:same",
      taskID: winner,
      initialEvents: [makeEvent(taskID: winner, sequence: 1)]
    )

    let repeated = try await store.claimSubmission(
      origin: "chatgpt",
      key: key,
      requestFingerprint: "sha256:same",
      taskID: loser,
      initialEvents: [makeEvent(taskID: loser, sequence: 1, kind: "task.competing")]
    )

    XCTAssertEqual(repeated, winner)
    let winnerEvents = try await store.events(for: winner)
    let loserEvents = try await store.events(for: loser)
    XCTAssertEqual(winnerEvents.map(\.kind), ["task.progress"])
    XCTAssertTrue(loserEvents.isEmpty)
  }

  func testEquivalentClaimsConvergeAcrossDatabaseConnections() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let stores = try (0..<4).map { _ in try EventStore(path: path) }
    let key = IdempotencyKey(rawValue: "submission-cross-connection")

    let results = try await withThrowingTaskGroup(of: TaskID.self) { group in
      for (index, store) in stores.enumerated() {
        group.addTask {
          try await store.claimSubmission(
            origin: "chatgpt",
            key: key,
            requestFingerprint: "sha256:cross-connection",
            taskID: TaskID(rawValue: "task-cross-\(index)")
          )
        }
      }

      var taskIDs: [TaskID] = []
      for try await taskID in group {
        taskIDs.append(taskID)
      }
      return taskIDs
    }

    XCTAssertEqual(Set(results).count, 1)
  }

  func testAppendUsesCASAndRollsBackStaleWriter() async throws {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "task-cas")
    let first = makeEvent(taskID: taskID, sequence: 1)
    try await store.append(first, expectedLastSequence: 0)

    do {
      try await store.append(
        makeEvent(taskID: taskID, sequence: 1, kind: "stale"),
        expectedLastSequence: 0
      )
      XCTFail("Expected a stale sequence conflict")
    } catch {
      XCTAssertEqual(
        error as? EventStoreError,
        .optimisticConcurrencyConflict(
          taskID: taskID,
          expectedLastSequence: 0,
          actualLastSequence: 1
        )
      )
    }

    let lastSequence = try await store.lastEventSequence(for: taskID)
    let storedEvents = try await store.events(for: taskID)
    XCTAssertEqual(lastSequence, 1)
    XCTAssertEqual(storedEvents, [first])
  }

  func testEventsAreReturnedInSequenceOrder() async throws {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "task-order")
    let events = (1...3).map { sequence in
      makeEvent(taskID: taskID, sequence: Int64(sequence))
    }

    for event in events {
      try await store.append(event, expectedLastSequence: event.sequence - 1)
    }

    let allEvents = try await store.events(for: taskID)
    let laterEvents = try await store.events(for: taskID, afterSequence: 1)
    XCTAssertEqual(allEvents, events)
    XCTAssertEqual(laterEvents, Array(events.dropFirst()))
  }

  func testSecondLockFailureLeavesNoFirstLock() async throws {
    let store = try EventStore.inMemory()
    let ownerA = TaskID(rawValue: "task-owner-a")
    let ownerB = TaskID(rawValue: "task-owner-b")
    try await store.acquireLocks(["held-a", "held-z"], ownerTaskID: ownerA)

    do {
      try await store.acquireLocks(["free-a", "held-z"], ownerTaskID: ownerB)
      XCTFail("Expected the second lock insertion to fail")
    } catch {
      XCTAssertEqual(error as? EventStoreError, .lockUnavailable("held-z"))
    }

    let freeLockOwner = try await store.lockOwner(for: "free-a")
    let heldLockOwner = try await store.lockOwner(for: "held-z")
    XCTAssertNil(freeLockOwner)
    XCTAssertEqual(heldLockOwner, ownerA)
  }

  func testOnlyOwnerCanAtomicallyReleaseItsTwoLocks() async throws {
    let store = try EventStore.inMemory()
    let owner = TaskID(rawValue: "task-lock-owner")
    let stranger = TaskID(rawValue: "task-lock-stranger")
    try await store.acquireLocks(["thread:one", "worktree:one"], ownerTaskID: owner)

    do {
      try await store.releaseLocks(
        ["thread:one", "worktree:one"],
        ownerTaskID: stranger
      )
      XCTFail("Expected lock ownership enforcement")
    } catch {
      XCTAssertEqual(error as? EventStoreError, .lockOwnershipMismatch("thread:one"))
    }
    let threadOwner = try await store.lockOwner(for: "thread:one")
    let worktreeOwner = try await store.lockOwner(for: "worktree:one")
    XCTAssertEqual(threadOwner, owner)
    XCTAssertEqual(worktreeOwner, owner)

    try await store.releaseLocks(["worktree:one", "thread:one"], ownerTaskID: owner)
    let releasedThreadOwner = try await store.lockOwner(for: "thread:one")
    let releasedWorktreeOwner = try await store.lockOwner(for: "worktree:one")
    XCTAssertNil(releasedThreadOwner)
    XCTAssertNil(releasedWorktreeOwner)
    try await store.releaseLocks(["thread:one", "worktree:one"], ownerTaskID: owner)
  }

  func testTaskAndOwnedLockQueriesAreStableAndOrdered() async throws {
    let store = try EventStore.inMemory()
    let owner = TaskID(rawValue: "task-query-owner")
    try await store.acquireLocks(["worktree:z", "thread:a"], ownerTaskID: owner)

    let taskIDs = try await store.taskIDs()
    let keys = try await store.lockKeysOwned(by: owner)
    XCTAssertEqual(taskIDs, [owner])
    XCTAssertEqual(keys, ["thread:a", "worktree:z"])
  }

  private func makeEvent(
    taskID: TaskID,
    sequence: Int64,
    kind: String = "task.progress"
  ) -> TaskEventEnvelope {
    TaskEventEnvelope(
      taskID: taskID,
      sequence: sequence,
      schemaVersion: 1,
      source: "test",
      kind: kind,
      severity: "info",
      payload: Data("{\"sequence\":\(sequence)}".utf8),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
    )
  }

  private func temporaryDatabasePath() -> String {
    FileManager.default.temporaryDirectory
      .appending(path: "codex-bridge-event-store-\(UUID().uuidString).sqlite")
      .path
  }

  private func removeDatabaseFiles(at path: String) {
    for candidate in [path, path + "-shm", path + "-wal"] {
      try? FileManager.default.removeItem(atPath: candidate)
    }
  }
}
