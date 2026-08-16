import BridgeDomain
import Foundation
import GRDB
import XCTest

@testable import BridgePersistence

final class TaskRetentionTests: XCTestCase {
  func testTerminalAppendArchivesAtomicallyAndPrunesHistorySafely() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let store = try EventStore(path: path)
    let taskID = TaskID(rawValue: "retention-atomic")
    let createdAt = timestamp(300)
    let startedAt = timestamp(310)
    let completedAt = timestamp(320)
    let initialEvents = [
      event(taskID, sequence: 1, kind: "task.submission", at: createdAt),
      event(taskID, sequence: 2, kind: "task.turnStarted", at: startedAt),
    ]
    _ = try await store.claimSubmission(
      origin: "retention-tests",
      key: IdempotencyKey(rawValue: "atomic"),
      requestFingerprint: "atomic-fingerprint",
      taskID: taskID,
      initialEvents: initialEvents,
      initialSnapshot: TaskStateSnapshot(
        taskID: taskID,
        lastEventSequence: 2,
        schemaVersion: 1,
        payload: Data("snapshot".utf8),
        recoveryRequired: false
      ),
      createdAt: createdAt
    )
    let metadata = try retainedMetadata(
      taskID,
      createdAt: createdAt,
      completedAt: completedAt,
      payload: Data("projection".utf8)
    )
    try await store.append(
      event(taskID, sequence: 3, kind: "task.completionRecorded", at: completedAt),
      expectedLastSequence: 2,
      snapshot: TaskStateSnapshot(
        taskID: taskID,
        lastEventSequence: 3,
        schemaVersion: 1,
        payload: Data("snapshot-terminal".utf8),
        recoveryRequired: false
      ),
      terminalMetadata: metadata
    )
    let retained = try await store.retainedMetadata(for: taskID)
    XCTAssertEqual(retained, metadata)

    _ = try await store.transitionRetainedMetadataHistory(
      taskID: taskID,
      expectedState: .full,
      to: .archiveAuthoritative,
      at: timestamp(321)
    )
    let prunedEventCount = try await store.pruneTaskEventHistory(
      taskID: taskID,
      expectedLastEventSequence: 3,
      expectedProjectionSHA256: metadata.projectionSHA256,
      at: timestamp(322)
    )
    XCTAssertEqual(prunedEventCount, 3)
    let eventsAfterPrune = try await store.events(for: taskID)
    XCTAssertTrue(eventsAfterPrune.isEmpty)
    _ = try await store.transitionRetainedMetadataHistory(
      taskID: taskID,
      expectedState: .archiveAuthoritative,
      to: .payloadsPruned,
      at: timestamp(323)
    )
    let metadataPurged = try await store.purgeTaskMetadata(
      taskID: taskID,
      expectedLastEventSequence: 3,
      expectedProjectionSHA256: metadata.projectionSHA256,
      at: timestamp(324)
    )
    XCTAssertTrue(metadataPurged)
    let lastEventSequence = try await store.lastEventSequence(for: taskID)
    XCTAssertNil(lastEventSequence)
  }

  func testPolicyDefaultsCASAndRestartPersistence() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let first = try EventStore(path: path)

    let defaults = try await first.taskRetentionPolicy()
    XCTAssertEqual(defaults.eventDays, 30)
    XCTAssertEqual(defaults.metadataDays, 90)
    XCTAssertNil(defaults.recentTaskLimit)
    XCTAssertEqual(defaults.revision, 1)

    let updated = try await first.updateTaskRetentionPolicy(
      eventDays: 14,
      metadataDays: 60,
      recentTaskLimit: 250,
      expectedRevision: 1,
      updatedAt: timestamp(10)
    )
    XCTAssertEqual(updated.revision, 2)

    do {
      _ = try await first.updateTaskRetentionPolicy(
        eventDays: 7,
        metadataDays: 30,
        recentTaskLimit: nil,
        expectedRevision: 1,
        updatedAt: timestamp(11)
      )
      XCTFail("Expected stale retention policy CAS to fail")
    } catch {
      XCTAssertEqual(
        error as? EventStoreError,
        .retentionPolicyConflict(expected: 1, actual: 2)
      )
    }

    let reopened = try EventStore(path: path)
    let persistedPolicy = try await reopened.taskRetentionPolicy()
    XCTAssertEqual(persistedPolicy, updated)
    for values in [(0, 90, nil), (30, 29, nil), (30, 90, 0), (30, 90, 10_001)] {
      do {
        _ = try await reopened.updateTaskRetentionPolicy(
          eventDays: values.0,
          metadataDays: values.1,
          recentTaskLimit: values.2,
          expectedRevision: 2,
          updatedAt: timestamp(12)
        )
        XCTFail("Expected invalid retention policy")
      } catch {
        XCTAssertEqual(error as? EventStoreError, .invalidArgument("retentionPolicy"))
      }
    }
  }

  func testTerminalMetadataTimelineMissingIndexAndHistoryCASPersist() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let store = try EventStore(path: path)
    let firstID = TaskID(rawValue: "retained-a")
    let secondID = TaskID(rawValue: "retained-b")
    try await installTask(
      firstID, createdAt: timestamp(100), completedAt: timestamp(130), in: store)
    try await installTask(
      secondID, createdAt: timestamp(200), completedAt: timestamp(230), in: store)

    let firstMissing = try await store.taskIDsMissingRetainedMetadata(limit: 1)
    let secondMissing = try await store.taskIDsMissingRetainedMetadata(
      afterTaskID: try XCTUnwrap(firstMissing.last),
      limit: 1
    )
    XCTAssertEqual(firstMissing, [firstID])
    XCTAssertEqual(secondMissing, [secondID])

    let storedTimeline = try await store.taskRetentionTimeline(for: firstID)
    let timeline = try XCTUnwrap(storedTimeline)
    XCTAssertEqual(timeline.createdAt, timestamp(100))
    XCTAssertEqual(timeline.startedAt, timestamp(115))
    XCTAssertEqual(timeline.lastEventAt, timestamp(130))
    XCTAssertEqual(timeline.lastEventSequence, 3)

    let metadata = try retainedMetadata(
      firstID,
      createdAt: timestamp(100),
      completedAt: timestamp(130),
      payload: Data("projection-a".utf8)
    )
    let firstIndex = try await store.indexTerminalRetainedMetadata(metadata)
    let repeatedIndex = try await store.indexTerminalRetainedMetadata(metadata)
    let remainingMissing = try await store.taskIDsMissingRetainedMetadata(limit: 10)
    XCTAssertEqual(firstIndex, metadata)
    XCTAssertEqual(repeatedIndex, metadata)
    XCTAssertEqual(remainingMissing, [secondID])

    do {
      _ = try await store.indexTerminalRetainedMetadata(
        try retainedMetadata(
          firstID,
          createdAt: timestamp(100),
          completedAt: timestamp(130),
          payload: Data("different".utf8)
        )
      )
      XCTFail("Expected immutable retained metadata conflict")
    } catch {
      XCTAssertEqual(error as? EventStoreError, .retainedMetadataConflict(firstID))
    }

    let archive = try await store.transitionRetainedMetadataHistory(
      taskID: firstID,
      expectedState: .full,
      to: .archiveAuthoritative,
      at: timestamp(140)
    )
    XCTAssertEqual(archive.historyState, .archiveAuthoritative)
    XCTAssertNil(archive.payloadsPrunedAt)
    let pruned = try await store.transitionRetainedMetadataHistory(
      taskID: firstID,
      expectedState: .archiveAuthoritative,
      to: .payloadsPruned,
      at: timestamp(150)
    )
    XCTAssertEqual(pruned.payloadsPrunedAt, timestamp(150))

    let reopened = try EventStore(path: path)
    let persisted = try await reopened.retainedMetadata(for: firstID)
    XCTAssertEqual(persisted, pruned)
  }

  func testRetainedMetadataRejectsBoundsAndDetectsDigestCorruption() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let taskID = TaskID(rawValue: "retained-corruption")
    let store = try EventStore(path: path)
    try await installTask(taskID, createdAt: timestamp(100), completedAt: timestamp(130), in: store)

    XCTAssertThrowsError(
      try retainedMetadata(
        taskID,
        createdAt: timestamp(100),
        completedAt: timestamp(130),
        payload: Data(repeating: 1, count: TaskRetainedMetadata.maximumProjectionBytes + 1)
      )
    ) { error in
      XCTAssertEqual(error as? EventStoreError, .invalidArgument("retainedMetadata"))
    }
    let metadata = try retainedMetadata(
      taskID,
      createdAt: timestamp(100),
      completedAt: timestamp(130),
      payload: Data("trusted".utf8)
    )
    try await store.indexTerminalRetainedMetadata(metadata)

    let tamper = try DatabaseQueue(path: path)
    try await tamper.write { db in
      try db.execute(
        sql: "UPDATE task_retained_metadata SET projection_sha256 = ? WHERE task_id = ?",
        arguments: [Data(repeating: 0xA5, count: 32), taskID.rawValue]
      )
    }
    do {
      _ = try await store.retainedMetadata(for: taskID)
      XCTFail("Expected digest corruption to fail closed")
    } catch {
      XCTAssertEqual(error as? EventStoreError, .retainedMetadataConflict(taskID))
    }
  }

  func testCandidateSelectionUsesAgeRecentLimitCursorAndSafetyState() async throws {
    let store = try EventStore.inMemory()
    let now = timestamp(200 * 86_400)
    let values: [(String, Int)] = [
      ("candidate-a", 40),
      ("candidate-b", 145),
      ("candidate-c", 195),
      ("candidate-d", 199),
    ]
    for (name, day) in values {
      let taskID = TaskID(rawValue: name)
      let completedAt = timestamp(day * 86_400)
      try await installTask(
        taskID,
        createdAt: completedAt.addingTimeInterval(-100),
        completedAt: completedAt,
        in: store
      )
      try await store.indexTerminalRetainedMetadata(
        retainedMetadata(
          taskID,
          createdAt: completedAt.addingTimeInterval(-100),
          completedAt: completedAt,
          payload: Data(name.utf8)
        )
      )
    }

    let ageCandidates = try await store.retentionCandidates(now: now, limit: 10)
    XCTAssertEqual(ageCandidates.map(\.metadata.taskID.rawValue), ["candidate-a", "candidate-b"])
    XCTAssertEqual(ageCandidates.map(\.targetTier), [.all, .payloads])

    _ = try await store.updateTaskRetentionPolicy(
      eventDays: 30,
      metadataDays: 90,
      recentTaskLimit: 2,
      expectedRevision: 1,
      updatedAt: now
    )
    let firstPage = try await store.retentionCandidates(now: now, limit: 1)
    let first = try XCTUnwrap(firstPage.first)
    let cursor = try TaskRetentionCandidateCursor(
      completedAt: first.metadata.completedAt,
      taskID: first.metadata.taskID
    )
    let secondPage = try await store.retentionCandidates(now: now, after: cursor, limit: 10)
    XCTAssertEqual(first.targetTier, .all)
    XCTAssertEqual(secondPage.map(\.metadata.taskID.rawValue), ["candidate-b"])
    XCTAssertEqual(secondPage.map(\.targetTier), [.all])

    try await store.acquireLocks(
      ["thread:candidate-b", "worktree:candidate-b"],
      ownerTaskID: TaskID(rawValue: "candidate-b")
    )
    let lockedFiltered = try await store.retentionCandidates(now: now, limit: 10)
    XCTAssertEqual(lockedFiltered.map(\.metadata.taskID.rawValue), ["candidate-a"])
  }

  func testJobPlanLeaseProgressRetryAndRestartAreDurable() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let taskID = TaskID(rawValue: "retention-job")
    let now = timestamp(200 * 86_400)
    let store = try EventStore(path: path)
    let completedAt = timestamp(100 * 86_400)
    try await installTask(
      taskID,
      createdAt: completedAt.addingTimeInterval(-100),
      completedAt: completedAt,
      in: store
    )
    try await store.indexTerminalRetainedMetadata(
      retainedMetadata(
        taskID,
        createdAt: completedAt.addingTimeInterval(-100),
        completedAt: completedAt,
        payload: Data("job-projection".utf8)
      )
    )
    let candidates = try await store.retentionCandidates(now: now, limit: 1)
    let candidate = try XCTUnwrap(candidates.first)
    let planned = try await store.planRetentionJob(for: candidate, at: now)
    XCTAssertEqual(planned.state, .prepared)
    XCTAssertEqual(planned.targetTier, .all)

    let claimed = try await store.claimRetentionJobs(
      ownerInstanceID: "instance-a",
      now: now,
      leaseUntil: now.addingTimeInterval(300),
      limit: 1
    )
    XCTAssertEqual(claimed.map(\.taskID), [taskID])
    let blockedClaim = try await store.claimRetentionJobs(
      ownerInstanceID: "instance-b",
      now: now.addingTimeInterval(1),
      leaseUntil: now.addingTimeInterval(301),
      limit: 1
    )
    XCTAssertTrue(blockedClaim.isEmpty)
    let progress = try await store.updateRetentionJobProgress(
      taskID: taskID,
      ownerInstanceID: "instance-a",
      expectedState: .prepared,
      eventCursor: 10,
      pipelineCursor: 20,
      supervisionCursor: 30,
      at: now.addingTimeInterval(2)
    )
    XCTAssertEqual(progress.eventCursor, 10)

    do {
      _ = try await store.advanceRetentionJob(
        taskID: taskID,
        ownerInstanceID: "instance-a",
        expectedState: .prepared,
        to: .supervisionPruned,
        at: now.addingTimeInterval(3)
      )
      XCTFail("Expected invalid state jump to fail")
    } catch {
      XCTAssertEqual(error as? EventStoreError, .retentionLeaseUnavailable(taskID))
    }
    let pruning = try await store.advanceRetentionJob(
      taskID: taskID,
      ownerInstanceID: "instance-a",
      expectedState: .prepared,
      to: .pipelinePruning,
      at: now.addingTimeInterval(4)
    )
    XCTAssertEqual(pruning.state, .pipelinePruning)
    try await store.releaseRetentionJob(
      taskID: taskID,
      ownerInstanceID: "instance-a",
      errorCode: "pipeline_busy",
      retryAt: now.addingTimeInterval(120),
      at: now.addingTimeInterval(5)
    )

    let status = try await store.taskRetentionStatus(now: now.addingTimeInterval(6))
    XCTAssertEqual(status.pendingJobCount, 1)
    XCTAssertEqual(status.leasedJobCount, 0)
    XCTAssertEqual(status.retryScheduledJobCount, 1)
    let beforeRetry = try await store.claimRetentionJobs(
      ownerInstanceID: "instance-b",
      now: now.addingTimeInterval(119),
      leaseUntil: now.addingTimeInterval(200),
      limit: 1
    )
    XCTAssertTrue(beforeRetry.isEmpty)

    let reopened = try EventStore(path: path)
    let recovered = try await reopened.claimRetentionJobs(
      ownerInstanceID: "instance-b",
      now: now.addingTimeInterval(120),
      leaseUntil: now.addingTimeInterval(220),
      limit: 1
    )
    XCTAssertEqual(recovered.first?.state, .pipelinePruning)
    XCTAssertEqual(recovered.first?.attemptCount, 1)
    XCTAssertEqual(recovered.first?.lastErrorCode, "pipeline_busy")
    XCTAssertEqual(recovered.first?.eventCursor, 10)
  }

  func testPayloadsCompleteIsReclaimedAfterCrashAndFinishedAfterRestart() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let taskID = TaskID(rawValue: "retention-payloads-crash")
    let now = timestamp(200 * 86_400)
    let completedAt = timestamp(150 * 86_400)
    let store = try EventStore(path: path)
    try await installTask(
      taskID,
      createdAt: completedAt.addingTimeInterval(-100),
      completedAt: completedAt,
      in: store
    )
    try await store.indexTerminalRetainedMetadata(
      retainedMetadata(
        taskID,
        createdAt: completedAt.addingTimeInterval(-100),
        completedAt: completedAt,
        payload: Data("payloads-crash".utf8)
      )
    )
    let candidates = try await store.retentionCandidates(now: now, limit: 1)
    let candidate = try XCTUnwrap(candidates.first)
    XCTAssertEqual(candidate.targetTier, .payloads)
    _ = try await store.planRetentionJob(for: candidate, at: now)
    _ = try await store.claimRetentionJobs(
      ownerInstanceID: "crashed-instance",
      now: now,
      leaseUntil: now.addingTimeInterval(30),
      limit: 1
    )

    let transitions: [(TaskRetentionJobState, TaskRetentionJobState)] = [
      (.prepared, .pipelinePruning),
      (.pipelinePruning, .pipelinePruned),
      (.pipelinePruned, .supervisionPruning),
      (.supervisionPruning, .supervisionPruned),
      (.supervisionPruned, .archiveAuthoritative),
      (.archiveAuthoritative, .eventHistoryPruning),
      (.eventHistoryPruning, .eventHistoryPruned),
      (.eventHistoryPruned, .externalPayloadsPruning),
      (.externalPayloadsPruning, .payloadsComplete),
    ]
    var payloadsComplete: TaskRetentionJob?
    for (offset, transition) in transitions.enumerated() {
      payloadsComplete = try await store.advanceRetentionJob(
        taskID: taskID,
        ownerInstanceID: "crashed-instance",
        expectedState: transition.0,
        to: transition.1,
        at: now.addingTimeInterval(TimeInterval(offset + 1))
      )
    }
    XCTAssertEqual(payloadsComplete?.state, .payloadsComplete)

    let reopened = try EventStore(path: path)
    let reclaimed = try await reopened.claimRetentionJobs(
      ownerInstanceID: "replacement-instance",
      now: now.addingTimeInterval(31),
      leaseUntil: now.addingTimeInterval(331),
      limit: 1
    )
    XCTAssertEqual(reclaimed.map(\.taskID), [taskID])
    XCTAssertEqual(reclaimed.first?.state, .payloadsComplete)
    let completed = try await reopened.advanceRetentionJob(
      taskID: taskID,
      ownerInstanceID: "replacement-instance",
      expectedState: .payloadsComplete,
      to: .complete,
      at: now.addingTimeInterval(32)
    )
    XCTAssertEqual(completed.state, .complete)
    XCTAssertNil(completed.leaseOwner)

    let status = try await reopened.taskRetentionStatus(now: now.addingTimeInterval(33))
    XCTAssertEqual(status.pendingJobCount, 0)
    XCTAssertEqual(status.completedJobCount, 1)
  }

  func testPayloadsPrunedMetadataDoesNotReenterUntilMetadataTierExpires() async throws {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "payloads-pruned-stable")
    let now = timestamp(200 * 86_400)
    let completedAt = timestamp(150 * 86_400)
    try await installTask(
      taskID,
      createdAt: completedAt.addingTimeInterval(-100),
      completedAt: completedAt,
      in: store
    )
    try await store.indexTerminalRetainedMetadata(
      retainedMetadata(
        taskID,
        createdAt: completedAt.addingTimeInterval(-100),
        completedAt: completedAt,
        payload: Data("payloads-pruned-stable".utf8)
      )
    )
    _ = try await store.transitionRetainedMetadataHistory(
      taskID: taskID,
      expectedState: .full,
      to: .archiveAuthoritative,
      at: now
    )
    _ = try await store.transitionRetainedMetadataHistory(
      taskID: taskID,
      expectedState: .archiveAuthoritative,
      to: .payloadsPruned,
      at: now
    )

    let beforeMetadataExpiry = try await store.retentionCandidates(now: now, limit: 1)
    XCTAssertTrue(beforeMetadataExpiry.isEmpty)

    _ = try await store.updateTaskRetentionPolicy(
      eventDays: 30,
      metadataDays: 40,
      recentTaskLimit: nil,
      expectedRevision: 1,
      updatedAt: now
    )
    let upgraded = try await store.retentionCandidates(now: now, limit: 1)
    XCTAssertEqual(upgraded.first?.metadata.taskID, taskID)
    XCTAssertEqual(upgraded.first?.targetTier, .all)
  }

  func testJobPlanningRejectsStalePolicyAndActiveLock() async throws {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "retention-stale")
    let now = timestamp(200 * 86_400)
    let completedAt = timestamp(100 * 86_400)
    try await installTask(
      taskID,
      createdAt: completedAt.addingTimeInterval(-100),
      completedAt: completedAt,
      in: store
    )
    try await store.indexTerminalRetainedMetadata(
      retainedMetadata(
        taskID,
        createdAt: completedAt.addingTimeInterval(-100),
        completedAt: completedAt,
        payload: Data("stale".utf8)
      )
    )
    let staleCandidates = try await store.retentionCandidates(now: now, limit: 1)
    let staleCandidate = try XCTUnwrap(staleCandidates.first)
    _ = try await store.updateTaskRetentionPolicy(
      eventDays: 29,
      metadataDays: 90,
      recentTaskLimit: nil,
      expectedRevision: 1,
      updatedAt: now
    )
    do {
      _ = try await store.planRetentionJob(for: staleCandidate, at: now)
      XCTFail("Expected stale policy to fail")
    } catch {
      XCTAssertEqual(
        error as? EventStoreError,
        .retentionPolicyConflict(expected: 1, actual: 2)
      )
    }

    let currentCandidates = try await store.retentionCandidates(now: now, limit: 1)
    let current = try XCTUnwrap(currentCandidates.first)
    try await store.acquireLocks(
      ["thread:stale", "worktree:stale"],
      ownerTaskID: taskID
    )
    do {
      _ = try await store.planRetentionJob(for: current, at: now)
      XCTFail("Expected lock to block retention plan")
    } catch {
      XCTAssertEqual(error as? EventStoreError, .retainedMetadataConflict(taskID))
    }
  }

  private func installTask(
    _ taskID: TaskID,
    createdAt: Date,
    completedAt: Date,
    in store: EventStore
  ) async throws {
    let startedAt = createdAt.addingTimeInterval((completedAt.timeIntervalSince(createdAt)) / 2)
    let events = [
      event(taskID, sequence: 1, kind: "task.submission", at: createdAt),
      event(taskID, sequence: 2, kind: "task.turnStarted", at: startedAt),
      event(taskID, sequence: 3, kind: "task.completionRecorded", at: completedAt),
    ]
    _ = try await store.claimSubmission(
      origin: "retention-tests",
      key: IdempotencyKey(rawValue: "key-\(taskID.rawValue)"),
      requestFingerprint: "fingerprint-\(taskID.rawValue)",
      taskID: taskID,
      initialEvents: events,
      initialSnapshot: TaskStateSnapshot(
        taskID: taskID,
        lastEventSequence: 3,
        schemaVersion: 1,
        payload: Data("snapshot-\(taskID.rawValue)".utf8),
        recoveryRequired: false
      ),
      createdAt: createdAt
    )
  }

  private func retainedMetadata(
    _ taskID: TaskID,
    createdAt: Date,
    completedAt: Date,
    payload: Data
  ) throws -> TaskRetainedMetadata {
    try TaskRetainedMetadata(
      taskID: taskID,
      terminalPhase: .completed,
      createdAt: createdAt,
      startedAt: createdAt.addingTimeInterval(completedAt.timeIntervalSince(createdAt) / 2),
      completedAt: completedAt,
      lastEventSequence: 3,
      projectionSchemaVersion: 1,
      projectionPayload: payload,
      indexedAt: completedAt
    )
  }

  private func event(
    _ taskID: TaskID,
    sequence: Int64,
    kind: String,
    at date: Date
  ) -> TaskEventEnvelope {
    TaskEventEnvelope(
      taskID: taskID,
      sequence: sequence,
      schemaVersion: 1,
      source: "test",
      kind: kind,
      severity: "info",
      payload: Data("{\"sequence\":\(sequence)}".utf8),
      createdAt: date
    )
  }

  private func timestamp<T: BinaryInteger>(_ offset: T) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + Double(Int64(offset)))
  }

  private func temporaryDatabasePath() -> String {
    FileManager.default.temporaryDirectory
      .appending(path: "codex-bridge-retention-\(UUID().uuidString).sqlite")
      .path
  }

  private func removeDatabaseFiles(at path: String) {
    let backup = try? DatabaseMigrationBackup.backupURL(
      databasePath: path,
      componentIdentifier: "BridgePersistence"
    ).path
    for candidate in [path, path + "-shm", path + "-wal", backup].compactMap({ $0 }) {
      try? FileManager.default.removeItem(atPath: candidate)
    }
  }
}
