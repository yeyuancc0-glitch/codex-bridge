import BridgeCoordinator
import BridgeDomain
import BridgePersistence
import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopTaskLifecycleCoordinatorTests: XCTestCase {
  func testTerminalNotificationCursorAndLedgerSurviveCoordinatorRestart() async throws {
    let store = try EventStore.inMemory()
    try await store.setNotificationsEnabled(true)
    let taskID = TaskID(rawValue: "task-lifecycle-restart")
    let projection = try Self.failedProjection(taskID: taskID)
    try await Self.appendFailedEvents(taskID: taskID, to: store)

    let firstNotifier = RecordingTaskNotifier()
    let first = await Self.makeCoordinator(
      store: store,
      projection: projection,
      notifier: firstNotifier,
      owner: "instance.first"
    )
    try await first.coordinator.start()
    let firstRequests = await firstNotifier.requests()
    let cursor = try await store.notificationConsumerCursor(
      DesktopTaskNotificationLedger.consumerID
    )
    XCTAssertEqual(firstRequests.count, 1)
    XCTAssertEqual(cursor, 2)
    await first.coordinator.shutdown()

    let secondNotifier = RecordingTaskNotifier()
    let second = await Self.makeCoordinator(
      store: store,
      projection: projection,
      notifier: secondNotifier,
      owner: "instance.second"
    )
    try await second.coordinator.start()
    let repeatedRequests = await secondNotifier.requests()
    XCTAssertTrue(repeatedRequests.isEmpty)
    await second.coordinator.shutdown()
  }

  func testDisabledNotificationsAdvanceCursorWithoutCreatingLedgerEntry() async throws {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "task-lifecycle-disabled")
    let projection = try Self.failedProjection(taskID: taskID)
    try await Self.appendFailedEvents(taskID: taskID, to: store)
    let notifier = RecordingTaskNotifier()
    let fixture = await Self.makeCoordinator(
      store: store,
      projection: projection,
      notifier: notifier,
      owner: "instance.disabled"
    )

    try await fixture.coordinator.start()

    let cursor = try await store.notificationConsumerCursor(
      DesktopTaskNotificationLedger.consumerID
    )
    let requests = await notifier.requests()
    XCTAssertEqual(cursor, 2)
    XCTAssertTrue(requests.isEmpty)
    await fixture.coordinator.shutdown()
  }

  func testPowerEventsCloseAdmissionAndWakeRevalidatesOnce() async throws {
    let store = try EventStore.inMemory()
    let projectionReader = StaticTaskProjectionReader(projections: [:])
    let notifier = RecordingTaskNotifier()
    let ledger = DesktopTaskNotificationLedger(store: store, ownerInstanceID: "power.instance")
    let power = await MainActor.run { ControllablePowerSource() }
    let connection = RecordingLifecycleConnection()
    let service = DesktopTaskLifecycleService(
      notifications: notifier,
      notificationStore: ledger,
      idleSleep: RecordingIdleSleepPreventer(),
      powerSource: power
    )
    let coordinator = DesktopTaskLifecycleCoordinator(
      eventStore: store,
      coordinator: projectionReader,
      service: service,
      connection: connection,
      ownerInstanceID: "power.instance",
      pollInterval: .seconds(60)
    )
    try await coordinator.start()

    await power.emit(.willSleep)
    try await Self.waitUntil { await connection.suspendCount == 1 }
    await power.emit(.didWake)
    try await Self.waitUntil { await connection.revalidationCount == 1 }

    let suspended = await connection.suspendCount
    let drains = await connection.drainCount
    XCTAssertEqual(suspended, 1)
    XCTAssertEqual(drains, 1)
    await coordinator.shutdown()
  }

  func testAuthorizationBoundarySkipsEventsCommittedWhileNotificationsWereDisabled()
    async throws
  {
    let store = try EventStore.inMemory()
    let taskID = TaskID(rawValue: "task-authorization-boundary")
    let projection = try Self.failedProjection(taskID: taskID)
    let notifier = AuthorizationBlockingNotifier()
    let authorizationStarted = Task { await nextValue(from: notifier.authorizationStarted) }
    let fixture = await Self.makeCoordinator(
      store: store,
      projections: [taskID: projection],
      notifier: notifier,
      owner: "instance.authorization"
    )
    try await fixture.coordinator.start()

    let enabling = Task { try await fixture.coordinator.updateNotificationsEnabled(true) }
    _ = await authorizationStarted.value
    try await Self.appendFailedEvents(taskID: taskID, to: store)
    await notifier.releaseAuthorization()
    try await enabling.value

    let cursor = try await store.notificationConsumerCursor(
      DesktopTaskNotificationLedger.consumerID
    )
    let preferences = try await store.lifecyclePreferences()
    let requests = await notifier.requests()
    XCTAssertEqual(cursor, 2)
    XCTAssertTrue(preferences.notificationsEnabled)
    XCTAssertTrue(requests.isEmpty)
    await fixture.coordinator.shutdown()
  }

  func testDrainProcessesAtMostOneThousandChangesPerRefresh() async throws {
    let store = try EventStore.inMemory()
    try await store.setNotificationsEnabled(true)
    let taskID = TaskID(rawValue: "task-drain-budget")
    for sequence in 1...1_001 {
      try await store.append(
        Self.event(
          taskID: taskID,
          sequence: Int64(sequence),
          kind: "task.progress"
        ),
        expectedLastSequence: Int64(sequence - 1)
      )
    }
    let fixture = await Self.makeCoordinator(
      store: store,
      projections: [:],
      notifier: RecordingTaskNotifier(),
      owner: "instance.budget"
    )

    try await fixture.coordinator.start()

    let cursor = try await store.notificationConsumerCursor(
      DesktopTaskNotificationLedger.consumerID
    )
    XCTAssertEqual(cursor, 1_000)
    await fixture.coordinator.shutdown()
  }

  func testUniqueInstanceImmediatelyTakesOverOldNotificationOwner() async throws {
    let store = try EventStore.inMemory()
    try await store.setNotificationsEnabled(true)
    let taskID = TaskID(rawValue: "task-owner-takeover")
    let projection = try Self.failedProjection(taskID: taskID)
    try await Self.appendFailedEvents(taskID: taskID, to: store)
    let changes = try await store.changes(after: 0, limit: 10)
    let terminalChange = try XCTUnwrap(changes.last)
    let identity = DesktopTaskTerminalNotification(
      taskID: taskID.rawValue,
      terminalEventSequence: terminalChange.eventSequence,
      kind: .failed
    )
    let now = Date()
    _ = try await store.reserveNotifications(
      consumerID: DesktopTaskNotificationLedger.consumerID,
      ownerInstanceID: "instance.crashed",
      expectedCursor: 0,
      throughChangeID: terminalChange.changeID,
      candidates: [
        TaskNotificationCandidate(
          stableKey: DesktopTaskNotificationLedger.stableKey(for: identity),
          change: terminalChange
        )
      ],
      reservedAt: now,
      leaseUntil: now.addingTimeInterval(3_000)
    )
    let notifier = RecordingTaskNotifier()
    let fixture = await Self.makeCoordinator(
      store: store,
      projections: [taskID: projection],
      notifier: notifier,
      owner: "instance.restarted"
    )

    try await fixture.coordinator.start()

    let requests = await notifier.requests()
    let reservation = try await store.notificationReservation(
      consumerID: DesktopTaskNotificationLedger.consumerID,
      stableKey: DesktopTaskNotificationLedger.stableKey(for: identity)
    )
    XCTAssertEqual(requests.count, 1)
    XCTAssertNil(reservation)
    await fixture.coordinator.shutdown()
  }

  func testConcurrentShutdownWaitsForSameCompleteBarrier() async throws {
    let store = try EventStore.inMemory()
    let connection = BlockingLifecycleConnection(blockDrain: true)
    let drainStarted = Task { await nextValue(from: connection.drainStarted) }
    let fixture = await Self.makeCoordinator(
      store: store,
      projections: [:],
      notifier: RecordingTaskNotifier(),
      owner: "instance.shutdown",
      connection: connection
    )
    try await fixture.coordinator.start()
    let first = Task { await fixture.coordinator.shutdown() }
    _ = await drainStarted.value
    let secondFinished = CompletionFlag()
    let second = Task {
      await fixture.coordinator.shutdown()
      await secondFinished.finish()
    }
    await Task.yield()
    let finishedBeforeRelease = await secondFinished.isFinished
    XCTAssertFalse(finishedBeforeRelease)

    await connection.releaseDrain()
    await first.value
    await second.value
    let finishedAfterRelease = await secondFinished.isFinished
    XCTAssertTrue(finishedAfterRelease)
  }

  func testWakeFinishingAfterShutdownCannotLeaveAdmissionsOpen() async throws {
    let store = try EventStore.inMemory()
    let connection = BlockingLifecycleConnection(blockRevalidation: true)
    let revalidationStarted = Task {
      await nextValue(from: connection.revalidationStarted)
    }
    let power = await MainActor.run { ControllablePowerSource() }
    let ledger = DesktopTaskNotificationLedger(
      store: store,
      ownerInstanceID: "instance.wake-shutdown"
    )
    let service = DesktopTaskLifecycleService(
      notifications: RecordingTaskNotifier(),
      notificationStore: ledger,
      idleSleep: RecordingIdleSleepPreventer(),
      powerSource: power
    )
    let coordinator = DesktopTaskLifecycleCoordinator(
      eventStore: store,
      coordinator: StaticTaskProjectionReader(projections: [:]),
      service: service,
      connection: connection,
      ownerInstanceID: "instance.wake-shutdown",
      pollInterval: .seconds(60)
    )
    try await coordinator.start()
    await power.emit(.didWake)
    _ = await revalidationStarted.value
    let shutdown = Task { await coordinator.shutdown() }
    try await Self.waitUntil { await connection.suspendCount > 0 }

    await connection.releaseRevalidation()
    await shutdown.value
    let admissionsOpen = await connection.admissionsOpen
    let suspendCount = await connection.suspendCount
    XCTAssertFalse(admissionsOpen)
    XCTAssertGreaterThanOrEqual(suspendCount, 2)
  }

  private struct Fixture {
    let coordinator: DesktopTaskLifecycleCoordinator
  }

  @MainActor
  private static func makeCoordinator(
    store: EventStore,
    projection: TaskProjection,
    notifier: RecordingTaskNotifier,
    owner: String
  ) -> Fixture {
    makeCoordinator(
      store: store,
      projections: [projection.aggregate.id: projection],
      notifier: notifier,
      owner: owner
    )
  }

  @MainActor
  private static func makeCoordinator(
    store: EventStore,
    projections: [TaskID: TaskProjection],
    notifier: any DesktopTaskNotificationDelivering,
    owner: String,
    connection: any DesktopLifecycleConnectionControlling = RecordingLifecycleConnection()
  ) -> Fixture {
    let ledger = DesktopTaskNotificationLedger(store: store, ownerInstanceID: owner)
    let service = DesktopTaskLifecycleService(
      notifications: notifier,
      notificationStore: ledger,
      idleSleep: RecordingIdleSleepPreventer(),
      powerSource: ControllablePowerSource(),
      notificationDeliveryEnabled: true
    )
    return Fixture(
      coordinator: DesktopTaskLifecycleCoordinator(
        eventStore: store,
        coordinator: StaticTaskProjectionReader(projections: projections),
        service: service,
        connection: connection,
        ownerInstanceID: owner,
        pollInterval: .seconds(60)
      )
    )
  }

  private static func failedProjection(taskID: TaskID) throws -> TaskProjection {
    let submission = TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "lifecycle-test"),
      projectID: ProjectID(rawValue: "project-lifecycle"),
      thread: .new,
      execution: ExecutionOptions(
        model: "gpt-test",
        effort: "high",
        permissionMode: "read-only",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(
        enabled: true,
        model: "gpt-5.6-luna",
        effort: "medium"
      ),
      contract: TaskContract(goal: "Test lifecycle", acceptanceCriteria: ["Failure is durable"])
    )
    let initial = TaskAggregate(id: taskID, submission: submission)
    let preparing = try TaskReducer.reduce(initial, event: .preparationStarted)
    let failed = try TaskReducer.reduce(preparing, event: .failureRecorded(reason: "fixture"))
    return TaskProjection(aggregate: failed, lastSequence: 2)
  }

  private static func appendFailedEvents(taskID: TaskID, to store: EventStore) async throws {
    try await store.append(
      event(taskID: taskID, sequence: 1, kind: "task.preparationStarted"),
      expectedLastSequence: 0
    )
    try await store.append(
      event(taskID: taskID, sequence: 2, kind: "task.failureRecorded"),
      expectedLastSequence: 1
    )
  }

  private static func event(taskID: TaskID, sequence: Int64, kind: String) -> TaskEventEnvelope {
    TaskEventEnvelope(
      taskID: taskID,
      sequence: sequence,
      schemaVersion: 1,
      source: "test",
      kind: kind,
      severity: "error",
      payload: Data("{}".utf8),
      createdAt: Date(timeIntervalSince1970: 10)
    )
  }

  private static func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for lifecycle state")
  }
}

private actor StaticTaskProjectionReader: DesktopTaskProjectionReading {
  private let projections: [TaskID: TaskProjection]

  init(projections: [TaskID: TaskProjection]) {
    self.projections = projections
  }

  func task(_ taskID: TaskID) throws -> TaskProjection {
    guard let projection = projections[taskID] else {
      throw TaskCoordinatorError.unknownTask(taskID)
    }
    return projection
  }
}

private actor RecordingTaskNotifier: DesktopTaskNotificationDelivering {
  private var delivered: [DesktopTaskNotificationRequest] = []

  func authorization() -> DesktopNotificationAuthorization { .authorized }
  func requestAuthorization() -> DesktopNotificationAuthorization { .authorized }
  func containsRequest(identifier _: String) -> Bool { false }

  func deliver(_ request: DesktopTaskNotificationRequest) {
    delivered.append(request)
  }

  func requests() -> [DesktopTaskNotificationRequest] { delivered }
}

private actor AuthorizationBlockingNotifier: DesktopTaskNotificationDelivering {
  nonisolated let authorizationStarted: AsyncStream<Void>

  private let authorizationStartedContinuation: AsyncStream<Void>.Continuation
  private var authorizationContinuation: CheckedContinuation<Void, Never>?
  private var delivered: [DesktopTaskNotificationRequest] = []

  init() {
    let pair = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    authorizationStarted = pair.stream
    authorizationStartedContinuation = pair.continuation
  }

  func authorization() -> DesktopNotificationAuthorization { .authorized }

  func requestAuthorization() async -> DesktopNotificationAuthorization {
    _ = authorizationStartedContinuation.yield(())
    await withCheckedContinuation { authorizationContinuation = $0 }
    return .authorized
  }

  func containsRequest(identifier _: String) -> Bool { false }

  func deliver(_ request: DesktopTaskNotificationRequest) {
    delivered.append(request)
  }

  func releaseAuthorization() {
    authorizationContinuation?.resume()
    authorizationContinuation = nil
  }

  func requests() -> [DesktopTaskNotificationRequest] { delivered }
}

private final class RecordingIdleSleepPreventer: DesktopIdleSleepPreventing, @unchecked Sendable {
  func begin(reason _: String) throws -> DesktopIdleSleepAssertion {
    DesktopIdleSleepAssertion()
  }

  func end(_: DesktopIdleSleepAssertion) {}
}

@MainActor
private final class ControllablePowerSource: DesktopPowerEventSourcing {
  nonisolated let events: AsyncStream<DesktopPowerEvent>
  private let continuation: AsyncStream<DesktopPowerEvent>.Continuation

  init() {
    let pair = AsyncStream.makeStream(
      of: DesktopPowerEvent.self,
      bufferingPolicy: .bufferingNewest(4)
    )
    events = pair.stream
    continuation = pair.continuation
  }

  func start() {}
  func stop() { continuation.finish() }
  func emit(_ event: DesktopPowerEvent) { continuation.yield(event) }
}

private actor RecordingLifecycleConnection: DesktopLifecycleConnectionControlling {
  private(set) var suspendCount = 0
  private(set) var drainCount = 0
  private(set) var revalidationCount = 0

  func suspendRemoteAdmissionsForSleep() {
    suspendCount += 1
  }

  func revalidateRemoteAdmissionsAfterWake() {
    revalidationCount += 1
  }

  func waitForRemoteSubmissionDrain() {
    drainCount += 1
  }
}

private actor BlockingLifecycleConnection: DesktopLifecycleConnectionControlling {
  nonisolated let drainStarted: AsyncStream<Void>
  nonisolated let revalidationStarted: AsyncStream<Void>

  private let drainStartedContinuation: AsyncStream<Void>.Continuation
  private let revalidationStartedContinuation: AsyncStream<Void>.Continuation
  private let blocksDrain: Bool
  private let blocksRevalidation: Bool
  private var drainContinuation: CheckedContinuation<Void, Never>?
  private var revalidationContinuation: CheckedContinuation<Void, Never>?
  private(set) var suspendCount = 0
  private(set) var admissionsOpen = false

  init(blockDrain: Bool = false, blockRevalidation: Bool = false) {
    blocksDrain = blockDrain
    blocksRevalidation = blockRevalidation
    let drainPair = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    drainStarted = drainPair.stream
    drainStartedContinuation = drainPair.continuation
    let revalidationPair = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    revalidationStarted = revalidationPair.stream
    revalidationStartedContinuation = revalidationPair.continuation
  }

  func suspendRemoteAdmissionsForSleep() {
    suspendCount += 1
    admissionsOpen = false
  }

  func revalidateRemoteAdmissionsAfterWake() async {
    _ = revalidationStartedContinuation.yield(())
    if blocksRevalidation {
      await withCheckedContinuation { revalidationContinuation = $0 }
    }
    admissionsOpen = true
  }

  func waitForRemoteSubmissionDrain() async {
    _ = drainStartedContinuation.yield(())
    if blocksDrain {
      await withCheckedContinuation { drainContinuation = $0 }
    }
  }

  func releaseDrain() {
    drainContinuation?.resume()
    drainContinuation = nil
  }

  func releaseRevalidation() {
    revalidationContinuation?.resume()
    revalidationContinuation = nil
  }
}

private actor CompletionFlag {
  private(set) var isFinished = false

  func finish() {
    isFinished = true
  }
}

private func nextValue<Element: Sendable>(from stream: AsyncStream<Element>) async -> Element? {
  var iterator = stream.makeAsyncIterator()
  return await iterator.next()
}
