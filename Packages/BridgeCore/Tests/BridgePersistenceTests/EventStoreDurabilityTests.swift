import BridgeDomain
import Foundation
import GRDB
import XCTest

@testable import BridgePersistence

final class EventStoreDurabilityTests: XCTestCase {
  func testChangeLogCoversEveryEventTransactionPathInGlobalOrder() async throws {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "task-change-paths")
    let initial = [event(taskID, 1, "initial.one"), event(taskID, 2, "initial.two")]
    _ = try await store.claimSubmission(
      origin: "test",
      key: IdempotencyKey(rawValue: "change-paths"),
      requestFingerprint: "fingerprint",
      taskID: taskID,
      initialEvents: initial
    )
    try await store.append(event(taskID, 3, "append"), expectedLastSequence: 2)
    try await store.appendBatch(
      [event(taskID, 4, "batch.one"), event(taskID, 5, "batch.two")],
      expectedLastSequence: 3,
      snapshot: snapshot(taskID, 5, recoveryRequired: true)
    )
    let provisional = ["thread:provisional", "worktree:change-paths"]
    let exact = ["thread:exact", "worktree:change-paths"]
    try await store.acquireLocks(provisional, ownerTaskID: taskID)
    try await store.appendRekeyingOwnedLocks(
      event(taskID, 6, "rekey"),
      expectedLastSequence: 5,
      from: provisional,
      to: exact
    )
    try await store.appendReleasingOwnedLocks(
      event(taskID, 7, "release"),
      expectedLastSequence: 6
    )
    try await store.acquireLocks(exact, ownerTaskID: taskID)
    try await store.appendBatchReleasingOwnedLocks(
      [event(taskID, 8, "final.one"), event(taskID, 9, "final.two")],
      expectedLastSequence: 7,
      snapshot: snapshot(taskID, 9, recoveryRequired: false)
    )

    let changes = try await store.changes(limit: 500)

    XCTAssertEqual(changes.map(\.changeID), Array(1...9).map(Int64.init))
    XCTAssertEqual(changes.map(\.eventSequence), Array(1...9).map(Int64.init))
    XCTAssertEqual(
      changes.map(\.kind),
      [
        "initial.one", "initial.two", "append", "batch.one", "batch.two", "rekey",
        "release", "final.one", "final.two",
      ]
    )
  }

  func testDurableCursorRecoversEveryChangeAfterWakeHintBufferOverflow() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let store = try EventStore(path: path)
    let taskID = TaskID(rawValue: "task-overflow")
    let hints = await store.taskChanges()
    for sequence in 1...32 {
      try await store.append(
        event(taskID, Int64(sequence), "change.\(sequence)"),
        expectedLastSequence: Int64(sequence - 1)
      )
    }
    var iterator = hints.makeAsyncIterator()
    let bufferedHint = await iterator.next()
    XCTAssertEqual(bufferedHint, taskID)

    let reopened = try EventStore(path: path)
    var cursor: Int64 = 0
    var recovered: [TaskChange] = []
    while true {
      let page = try await reopened.changes(after: cursor, limit: 7)
      guard !page.isEmpty else { break }
      recovered += page
      cursor = try XCTUnwrap(page.last?.changeID)
    }

    XCTAssertEqual(recovered.map(\.eventSequence), Array(1...32).map(Int64.init))
    for (after, limit) in [(-1, 1), (0, 0), (0, 501)] {
      do {
        _ = try await reopened.changes(after: Int64(after), limit: limit)
        XCTFail("Expected invalid cursor arguments")
      } catch {
        XCTAssertEqual(
          error as? EventStoreError,
          after < 0 ? .invalidArgument("changeID") : .invalidArgument("limit")
        )
      }
    }
  }

  func testActiveSnapshotAndRecoveryQueriesPageBeyondFiveHundredAuthoritatively()
    async throws
  {
    let store = try EventStore.inMemory()
    for index in 0..<501 {
      let value = String(format: "%03d", index)
      let taskID = TaskID(rawValue: "task-active-\(value)")
      _ = try await store.claimSubmission(
        origin: "test",
        key: IdempotencyKey(rawValue: "active-\(value)"),
        requestFingerprint: "fingerprint-\(value)",
        taskID: taskID,
        initialEvents: [event(taskID, 1, "active")],
        initialSnapshot: snapshot(taskID, 1, recoveryRequired: true)
      )
    }

    let first = try await store.taskIDsWithActiveSnapshots(limit: 500)
    let second = try await store.taskIDsWithActiveSnapshots(
      afterTaskID: try XCTUnwrap(first.last),
      limit: 500
    )
    XCTAssertEqual(first.count, 500)
    XCTAssertEqual(second, [TaskID(rawValue: "task-active-500")])

    let staleID = TaskID(rawValue: "task-active-000")
    try await store.append(event(staleID, 2, "stale"), expectedLastSequence: 1)
    let activeAfterStale = try await store.taskIDsWithActiveSnapshots(limit: 500)
    let recovery = try await store.taskIDsRequiringRecovery(limit: 500)
    XCTAssertFalse(activeAfterStale.contains(staleID))
    XCTAssertTrue(recovery.contains(staleID))
  }

  func testNotificationReservationAndCursorSurviveRestartWithStableRetryIdentity()
    async throws
  {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let writer = try EventStore(path: path)
    let taskID = TaskID(rawValue: "task-notification-restart")
    for sequence in 1...3 {
      try await writer.append(
        event(taskID, Int64(sequence), "notification.\(sequence)"),
        expectedLastSequence: Int64(sequence - 1)
      )
    }
    let changes = try await writer.changes(limit: 10)
    _ = try await writer.reserveNotifications(
      consumerID: "desktop.notifications",
      ownerInstanceID: "instance.a",
      expectedCursor: 0,
      throughChangeID: changes[0].changeID,
      candidates: [],
      reservedAt: timestamp(100),
      leaseUntil: timestamp(150)
    )
    let candidates = changes.dropFirst().map {
      TaskNotificationCandidate(stableKey: "notice.\($0.changeID)", change: $0)
    }
    let reserved = try await writer.reserveNotifications(
      consumerID: "desktop.notifications",
      ownerInstanceID: "instance.a",
      expectedCursor: changes[0].changeID,
      throughChangeID: changes[2].changeID,
      candidates: candidates,
      reservedAt: timestamp(101),
      leaseUntil: timestamp(150)
    )
    XCTAssertEqual(reserved.map(\.state), [.reserved, .reserved])

    let restarted = try EventStore(path: path)
    let blocked = try await restarted.claimPendingNotificationReservations(
      consumerID: "desktop.notifications",
      ownerInstanceID: "instance.b",
      now: timestamp(149),
      leaseUntil: timestamp(199),
      limit: 10
    )
    XCTAssertTrue(blocked.isEmpty)
    let pending = try await restarted.claimPendingNotificationReservations(
      consumerID: "desktop.notifications",
      ownerInstanceID: "instance.b",
      now: timestamp(149),
      leaseUntil: timestamp(199),
      allowOwnerTakeover: true,
      limit: 10
    )
    let cursor = try await restarted.notificationConsumerCursor("desktop.notifications")
    XCTAssertEqual(pending.map(\.stableKey), ["notice.2", "notice.3"])
    XCTAssertEqual(cursor, changes[2].changeID)
    let scheduled = try await restarted.markNotificationScheduled(
      consumerID: "desktop.notifications",
      stableKey: "notice.2",
      ownerInstanceID: "instance.b",
      scheduledAt: timestamp(152)
    )
    let repeated = try await restarted.markNotificationScheduled(
      consumerID: "desktop.notifications",
      stableKey: "notice.2",
      ownerInstanceID: "instance.b",
      scheduledAt: timestamp(153)
    )
    XCTAssertEqual(scheduled, repeated)
    XCTAssertEqual(scheduled.state, .scheduled)
    XCTAssertEqual(scheduled.scheduledAt, timestamp(152))
    let remaining = try await restarted.claimPendingNotificationReservations(
      consumerID: "desktop.notifications",
      ownerInstanceID: "instance.b",
      now: timestamp(153),
      leaseUntil: timestamp(203),
      limit: 10
    )
    XCTAssertEqual(remaining.map(\.stableKey), ["notice.3"])
  }

  func testConcurrentConnectionsAtomicallyReserveOneNotification() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let writer = try EventStore(path: path)
    let taskID = TaskID(rawValue: "task-notification-concurrent")
    try await writer.append(event(taskID, 1, "completed"), expectedLastSequence: 0)
    let writtenChanges = try await writer.changes(limit: 1)
    let change = try XCTUnwrap(writtenChanges.first)
    let candidate = TaskNotificationCandidate(stableKey: "notice.concurrent", change: change)
    let first = try EventStore(path: path)
    let second = try EventStore(path: path)
    let reservedAt = timestamp(200)
    let leaseUntil = timestamp(300)
    let owners = [(first, "instance.a"), (second, "instance.b")]

    let successes = await withTaskGroup(of: Bool.self) { group in
      for (store, owner) in owners {
        group.addTask {
          do {
            _ = try await store.reserveNotifications(
              consumerID: "desktop.notifications",
              ownerInstanceID: owner,
              expectedCursor: 0,
              throughChangeID: change.changeID,
              candidates: [candidate],
              reservedAt: reservedAt,
              leaseUntil: leaseUntil
            )
            return true
          } catch EventStoreError.notificationCursorConflict {
            return false
          } catch {
            return false
          }
        }
      }
      var values: [Bool] = []
      for await value in group { values.append(value) }
      return values
    }

    XCTAssertEqual(successes.filter { $0 }.count, 1)
    let storedValue = try await writer.notificationReservation(
      consumerID: "desktop.notifications",
      stableKey: candidate.stableKey
    )
    let stored = try XCTUnwrap(storedValue)
    let otherOwner = stored.ownerInstanceID == "instance.a" ? "instance.b" : "instance.a"
    let blocked = try await writer.claimPendingNotificationReservations(
      consumerID: "desktop.notifications",
      ownerInstanceID: otherOwner,
      now: timestamp(250),
      leaseUntil: timestamp(350),
      limit: 10
    )
    XCTAssertTrue(blocked.isEmpty)
    try await writer.releaseNotificationReservation(
      consumerID: "desktop.notifications",
      stableKey: candidate.stableKey,
      ownerInstanceID: stored.ownerInstanceID,
      now: timestamp(250)
    )
    let claimed = try await writer.claimPendingNotificationReservations(
      consumerID: "desktop.notifications",
      ownerInstanceID: otherOwner,
      now: timestamp(250),
      leaseUntil: timestamp(350),
      limit: 10
    )
    XCTAssertEqual(claimed.map(\.stableKey), [candidate.stableKey])
  }

  func testNotificationPruningIsBoundedPreservesReservedAndKeepsMonotonicHead()
    async throws
  {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "task-prune")
    for sequence in 1...5 {
      try await store.append(
        event(taskID, Int64(sequence), "prune.\(sequence)"),
        expectedLastSequence: Int64(sequence - 1)
      )
    }
    let changes = try await store.changes(limit: 10)
    let candidates = changes.prefix(2).map {
      TaskNotificationCandidate(stableKey: "prune.\($0.changeID)", change: $0)
    }
    _ = try await store.reserveNotifications(
      consumerID: "consumer.a",
      ownerInstanceID: "instance.a",
      expectedCursor: 0,
      throughChangeID: changes[2].changeID,
      candidates: candidates,
      reservedAt: timestamp(100),
      leaseUntil: timestamp(150)
    )
    _ = try await store.markNotificationScheduled(
      consumerID: "consumer.a",
      stableKey: candidates[0].stableKey,
      ownerInstanceID: "instance.a",
      scheduledAt: timestamp(110)
    )
    _ = try await store.fastForwardNotificationConsumer(
      consumerID: "consumer.b",
      expectedCursor: 0,
      throughChangeID: changes[0].changeID,
      at: timestamp(111)
    )

    let first = try await store.pruneNotificationHistory(limit: 1)
    let reserved = try await store.notificationReservation(
      consumerID: "consumer.a",
      stableKey: candidates[1].stableKey
    )
    XCTAssertEqual(first.totalDeleted, 1)
    XCTAssertEqual(first.scheduledReservationsDeleted, 1)
    XCTAssertEqual(reserved?.state, .reserved)
    let afterFirst = try await store.changes(limit: 10)
    XCTAssertEqual(afterFirst.count, 5)

    let second = try await store.pruneNotificationHistory(limit: 1)
    let afterSecond = try await store.changes(limit: 10)
    let headAfterSecond = try await store.taskChangeHead()
    XCTAssertEqual(
      second,
      TaskNotificationPruneResult(
        scheduledReservationsDeleted: 0,
        changesDeleted: 1
      )
    )
    XCTAssertEqual(afterSecond.map(\.eventSequence), [2, 3, 4, 5])
    XCTAssertEqual(headAfterSecond, 5)

    _ = try await store.fastForwardNotificationConsumer(
      consumerID: "consumer.b",
      expectedCursor: changes[0].changeID,
      throughChangeID: changes[2].changeID,
      at: timestamp(112)
    )
    let third = try await store.pruneNotificationHistory()
    let afterThird = try await store.changes(limit: 10)
    XCTAssertEqual(third.changesDeleted, 1)
    XCTAssertEqual(afterThird.map(\.eventSequence), [2, 4, 5])

    _ = try await store.markNotificationScheduled(
      consumerID: "consumer.a",
      stableKey: candidates[1].stableKey,
      ownerInstanceID: "instance.a",
      scheduledAt: timestamp(113)
    )
    let scheduledPrune = try await store.pruneNotificationHistory(limit: 1)
    let scheduledChangePrune = try await store.pruneNotificationHistory(limit: 1)
    XCTAssertEqual(scheduledPrune.totalDeleted, 1)
    XCTAssertEqual(scheduledChangePrune.changesDeleted, 1)

    for consumerID in ["consumer.a", "consumer.b"] {
      _ = try await store.fastForwardNotificationConsumer(
        consumerID: consumerID,
        expectedCursor: changes[2].changeID,
        throughChangeID: changes[4].changeID,
        at: timestamp(114)
      )
    }
    let finalPrune = try await store.pruneNotificationHistory()
    let remainingChanges = try await store.changes(limit: 10)
    let retainedHead = try await store.taskChangeHead()
    XCTAssertEqual(finalPrune.changesDeleted, 2)
    XCTAssertTrue(remainingChanges.isEmpty)
    XCTAssertEqual(retainedHead, 5)

    try await store.append(event(taskID, 6, "prune.future"), expectedLastSequence: 5)
    let futureChanges = try await store.changes(after: 5, limit: 1)
    let future = try XCTUnwrap(futureChanges.first)
    let futureHead = try await store.taskChangeHead()
    XCTAssertEqual(future.changeID, 6)
    XCTAssertEqual(futureHead, 6)
  }

  func testLifecyclePreferencesAreTypedAndSharedAcrossInstances() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let first = try EventStore(path: path)
    let initial = try await first.lifecyclePreferences()
    XCTAssertEqual(initial, .defaults)
    let second = try EventStore(path: path)
    let notificationUpdateDate = timestamp(300)
    let sleepUpdateDate = timestamp(301)
    let receivingPauseUpdateDate = timestamp(302)
    async let notifications: Void = first.setNotificationsEnabled(
      true,
      updatedAt: notificationUpdateDate
    )
    async let idleSleep: Void = second.setIdleSleepEnabled(false, updatedAt: sleepUpdateDate)
    async let receivingPaused: Void = first.setReceivingPaused(
      true,
      updatedAt: receivingPauseUpdateDate
    )
    _ = try await (notifications, idleSleep, receivingPaused)

    let restarted = try EventStore(path: path)
    let persisted = try await restarted.lifecyclePreferences()
    XCTAssertEqual(
      persisted,
      LifecyclePreferences(
        notificationsEnabled: true,
        idleSleepEnabled: false,
        receivingPaused: true
      )
    )
    try await restarted.setNotificationsEnabled(false, updatedAt: timestamp(303))
    try await restarted.setIdleSleepEnabled(true, updatedAt: timestamp(304))
    try await restarted.setReceivingPaused(false, updatedAt: timestamp(305))
    let restored = try await first.lifecyclePreferences()
    XCTAssertEqual(restored, .defaults)
  }

  func testNotificationPreferenceAndConsumerBoundaryCommitAtomically() async throws {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "task-notification-preference-boundary")
    for sequence in 1...3 {
      try await store.append(
        event(taskID, Int64(sequence), "historical.\(sequence)"),
        expectedLastSequence: Int64(sequence - 1)
      )
    }

    let enabledHead = try await store.setNotificationsEnabled(
      true,
      consumerID: "desktop.notifications",
      expectedCursor: 0,
      updatedAt: timestamp(350)
    )
    let enabledCursor = try await store.notificationConsumerCursor("desktop.notifications")
    let enabledPreferences = try await store.lifecyclePreferences()
    XCTAssertEqual(enabledCursor, enabledHead)
    XCTAssertTrue(enabledPreferences.notificationsEnabled)

    try await store.append(event(taskID, 4, "future"), expectedLastSequence: 3)
    do {
      _ = try await store.setNotificationsEnabled(
        false,
        consumerID: "desktop.notifications",
        expectedCursor: 0,
        updatedAt: timestamp(351)
      )
      XCTFail("Expected the stale preference boundary to roll back.")
    } catch {
      XCTAssertEqual(
        error as? EventStoreError,
        .notificationCursorConflict(
          consumerID: "desktop.notifications",
          expected: 0,
          actual: enabledHead
        )
      )
    }
    let preferencesAfterConflict = try await store.lifecyclePreferences()
    XCTAssertTrue(preferencesAfterConflict.notificationsEnabled)

    let disabledHead = try await store.setNotificationsEnabled(
      false,
      consumerID: "desktop.notifications",
      expectedCursor: enabledHead,
      updatedAt: timestamp(352)
    )
    let disabledCursor = try await store.notificationConsumerCursor("desktop.notifications")
    let disabledPreferences = try await store.lifecyclePreferences()
    XCTAssertEqual(disabledCursor, disabledHead)
    XCTAssertFalse(disabledPreferences.notificationsEnabled)
  }

  func testDisabledNotificationConsumerFastForwardsAtomicallyAndFutureChangesRemainPaged()
    async throws
  {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    let store = try EventStore(path: path)
    let taskID = TaskID(rawValue: "task-fast-forward")
    for sequence in 1...20 {
      try await store.append(
        event(taskID, Int64(sequence), "historical.\(sequence)"),
        expectedLastSequence: Int64(sequence - 1)
      )
    }
    let head = try await store.taskChangeHead()

    let advanced = try await store.fastForwardNotificationConsumer(
      consumerID: "desktop.notifications",
      expectedCursor: 0,
      throughChangeID: head,
      at: timestamp(400)
    )

    let storedCursor = try await store.notificationConsumerCursor("desktop.notifications")
    XCTAssertEqual(advanced, head)
    XCTAssertEqual(storedCursor, head)
    do {
      _ = try await store.fastForwardNotificationConsumer(
        consumerID: "desktop.notifications",
        expectedCursor: 0,
        throughChangeID: head,
        at: timestamp(401)
      )
      XCTFail("Expected stale notification cursor")
    } catch {
      XCTAssertEqual(
        error as? EventStoreError,
        .notificationCursorConflict(
          consumerID: "desktop.notifications",
          expected: 0,
          actual: head
        )
      )
    }
    try await store.append(event(taskID, 21, "future"), expectedLastSequence: 20)
    let future = try await store.changes(after: head, limit: 1)
    let futureHead = try await store.taskChangeHead()
    XCTAssertEqual(future.map(\.eventSequence), [21])
    XCTAssertEqual(futureHead, future[0].changeID)
  }

  func testLegacyMigrationDoesNotBackfillAndTriggerRecordsOnlyFutureEvents() async throws {
    let path = temporaryDatabasePath()
    defer { removeDatabaseFiles(at: path) }
    _ = try EventStore(path: path)
    let database = try DatabaseQueue(path: path)
    try await database.write { db in
      try db.execute(sql: "DROP TRIGGER task_events_insert_change_log")
      try db.execute(sql: "DROP TABLE lifecycle_preferences")
      try db.execute(sql: "DROP TABLE task_notification_ledger")
      try db.execute(sql: "DROP TABLE task_notification_consumers")
      try db.execute(sql: "DROP TABLE task_change_state")
      try db.execute(sql: "DROP TABLE task_change_log")
      try db.execute(
        sql: """
          DELETE FROM grdb_migrations
          WHERE identifier IN (
            'addDurableTaskChangeLog',
            'addTaskNotificationLedger',
            'addTaskNotificationLeases',
            'addLifecyclePreferences',
            'addTaskChangeHeadState',
            'addReceivingPausePreference'
          )
          """)
      try db.execute(
        sql: """
          INSERT INTO tasks (task_id, last_event_seq, created_at, updated_at)
          VALUES ('legacy-task', 1, 10, 11)
          """)
      try db.execute(
        sql: """
          INSERT INTO task_events (
              task_id, seq, schema_version, source, kind, severity, payload, created_at
          ) VALUES ('legacy-task', 1, 1, 'legacy', 'legacy.completed', 'info', X'00', 11)
          """)
    }

    let migrated = try EventStore(path: path)
    let migratedChanges = try await migrated.changes(limit: 10)
    let migratedHead = try await migrated.taskChangeHead()
    XCTAssertTrue(migratedChanges.isEmpty)
    XCTAssertEqual(migratedHead, 0)
    let emptyHead = try await migrated.fastForwardNotificationConsumer(
      consumerID: "desktop.notifications",
      expectedCursor: 0,
      throughChangeID: 0,
      at: timestamp(500)
    )
    XCTAssertEqual(emptyHead, 0)
    let legacyTaskID = TaskID(rawValue: "legacy-task")
    try await migrated.append(
      event(legacyTaskID, 2, "legacy.future"),
      expectedLastSequence: 1
    )
    let changes = try await migrated.changes(limit: 10)
    XCTAssertEqual(changes.map(\.taskID), [legacyTaskID])
    XCTAssertEqual(changes.map(\.eventSequence), [2])
    XCTAssertEqual(changes.map(\.kind), ["legacy.future"])
    let futureHead = try await migrated.taskChangeHead()
    XCTAssertEqual(futureHead, 1)
    let preferences = try await migrated.lifecyclePreferences()
    XCTAssertEqual(preferences, .defaults)
  }

  private func event(_ taskID: TaskID, _ sequence: Int64, _ kind: String) -> TaskEventEnvelope {
    TaskEventEnvelope(
      taskID: taskID,
      sequence: sequence,
      schemaVersion: 1,
      source: "test",
      kind: kind,
      severity: "info",
      payload: Data("{}".utf8),
      createdAt: timestamp(sequence)
    )
  }

  private func snapshot(
    _ taskID: TaskID,
    _ sequence: Int64,
    recoveryRequired: Bool
  ) -> TaskStateSnapshot {
    TaskStateSnapshot(
      taskID: taskID,
      lastEventSequence: sequence,
      schemaVersion: 1,
      payload: Data("snapshot".utf8),
      recoveryRequired: recoveryRequired
    )
  }

  private func timestamp<T: BinaryInteger>(_ offset: T) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + Double(Int64(offset)))
  }

  private func temporaryDatabasePath() -> String {
    FileManager.default.temporaryDirectory
      .appending(path: "codex-bridge-durable-store-\(UUID().uuidString).sqlite")
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
