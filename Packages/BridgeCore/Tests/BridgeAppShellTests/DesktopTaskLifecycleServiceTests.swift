import BridgeSecurity
import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopTaskLifecycleServiceTests: XCTestCase {
  func testNotificationRouteRoundTripsOnlyBoundedSafeTaskIdentity() throws {
    let identity = Self.identity(taskID: "tsk_safe-notification", sequence: 42, kind: .completed)
    let route = try XCTUnwrap(DesktopTaskNotificationRoute(identity: identity))

    XCTAssertEqual(DesktopTaskNotificationRoute(userInfo: route.userInfo), route)
    XCTAssertNil(
      DesktopTaskNotificationRoute(
        identity: Self.identity(
          taskID: "/Users/alice/private-task",
          sequence: 43,
          kind: .failed
        )
      )
    )
    var malformed = route.userInfo
    malformed["codex_bridge_terminal_event_sequence"] = "042"
    XCTAssertNil(DesktopTaskNotificationRoute(userInfo: malformed))
  }

  func testNotificationUsesFixedSanitizedContentAndStableIdentifier() async throws {
    let fixture = await Self.fixture(notificationDeliveryEnabled: true)
    let unsafeTaskID = "Bearer secret-value-at-least-sixteen /Volumes/private/project"
    let identity = Self.identity(taskID: unsafeTaskID, sequence: 42, kind: .completed)

    let delivered = try await fixture.service.deliverCompletion(identity)
    XCTAssertEqual(delivered, .delivered)
    let deliveredRequests = await fixture.notifications.requests()
    let request = try XCTUnwrap(deliveredRequests.first)
    XCTAssertEqual(request.title, "任务已完成")
    XCTAssertEqual(request.body, "Codex Bridge 已保存任务的最终报告。")
    XCTAssertTrue(OutboundContentSecurity.isSafe(request.title))
    XCTAssertTrue(OutboundContentSecurity.isSafe(request.body))
    XCTAssertFalse(request.requestIdentifier.contains(unsafeTaskID))
    XCTAssertTrue(request.requestIdentifier.contains(".42.completed"))

    let duplicate = try await fixture.service.deliverCompletion(identity)
    XCTAssertEqual(duplicate, .duplicate)
    let requests = await fixture.notifications.requests()
    XCTAssertEqual(requests.count, 1)
  }

  func testDurableScheduledRecordDeduplicatesAcrossServiceRestart() async throws {
    let store = FakeDesktopTaskNotificationStore()
    let first = await Self.fixture(
      store: store,
      notificationDeliveryEnabled: true
    )
    let identity = Self.identity(sequence: 9, kind: .failed)
    let firstDelivery = try await first.service.deliverCompletion(identity)
    XCTAssertEqual(firstDelivery, .delivered)
    await first.service.shutdown()

    let second = await Self.fixture(
      store: store,
      notificationDeliveryEnabled: true
    )
    let secondDelivery = try await second.service.deliverCompletion(identity)
    let secondRequestCount = await second.notifications.requests().count
    let reserveCount = await store.reserveCount(for: identity)
    XCTAssertEqual(secondDelivery, .duplicate)
    XCTAssertEqual(secondRequestCount, 0)
    XCTAssertEqual(reserveCount, 2)
  }

  func testCrashWindowRetriesWithSameSystemRequestIdentifier() async throws {
    let store = FakeDesktopTaskNotificationStore()
    await store.failNextMarkScheduled()
    let first = await Self.fixture(
      store: store,
      notificationDeliveryEnabled: true
    )
    let identity = Self.identity(sequence: 11, kind: .cancelled)
    do {
      _ = try await first.service.deliverCompletion(identity)
      XCTFail("Expected durable mark failure")
    } catch {
      XCTAssertEqual(error as? DesktopTaskLifecycleError, .notificationStoreFailed)
    }
    let firstRequests = await first.notifications.requests()
    let firstIdentifier = try XCTUnwrap(firstRequests.first?.requestIdentifier)
    await first.service.shutdown()

    let second = await Self.fixture(
      store: store,
      notificationDeliveryEnabled: true
    )
    let retryDelivery = try await second.service.deliverCompletion(identity)
    let retryRequests = await second.notifications.requests()
    let retryIdentifier = try XCTUnwrap(retryRequests.first?.requestIdentifier)
    let lastReservation = await store.lastReservation(for: identity)
    XCTAssertEqual(retryDelivery, .delivered)
    XCTAssertEqual(retryIdentifier, firstIdentifier)
    XCTAssertEqual(lastReservation, .retry)
  }

  func testConcurrentDeliveryUsesOneReservationAndOneSystemRequest() async throws {
    let fixture = await Self.fixture(notificationDeliveryEnabled: true)
    await fixture.notifications.blockNextDelivery()
    let identity = Self.identity(sequence: 12)
    let started = Task { await nextValue(from: fixture.notifications.deliveryStarted) }
    let first = Task { try await fixture.service.deliverCompletion(identity) }
    _ = await started.value

    let concurrent = try await fixture.service.deliverCompletion(identity)
    XCTAssertEqual(concurrent, .inProgress)
    await fixture.notifications.releaseDelivery()
    let firstDelivery = try await first.value
    let requestCount = await fixture.notifications.requests().count
    let reserveCount = await fixture.store.reserveCount(for: identity)
    XCTAssertEqual(firstDelivery, .delivered)
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(reserveCount, 1)
  }

  func testShutdownWaitsForReservationAndPreventsPostGateDelivery() async throws {
    let fixture = await Self.fixture(notificationDeliveryEnabled: true)
    await fixture.store.blockNextReserve()
    let identity = Self.identity(sequence: 13)
    let reserveStarted = Task { await nextValue(from: fixture.store.reserveStarted) }
    let delivery = Task { try await fixture.service.deliverCompletion(identity) }
    _ = await reserveStarted.value

    let shutdown = Task { await fixture.service.shutdown() }
    try await waitForStopping(fixture.service)
    let stopping = await fixture.service.snapshot()
    XCTAssertTrue(stopping.isStopping)
    XCTAssertEqual(stopping.inFlightNotificationCount, 1)

    await fixture.store.releaseReserve()
    do {
      _ = try await delivery.value
      XCTFail("Expected shutdown gate to reject delivery")
    } catch {
      XCTAssertEqual(error as? DesktopTaskLifecycleError, .serviceStopped)
    }
    await shutdown.value
    let requestCount = await fixture.notifications.requests().count
    let retryCount = await fixture.store.retryCount(for: identity)
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(retryCount, 1)
    do {
      _ = try await fixture.service.deliverCompletion(Self.identity(sequence: 14))
      XCTFail("Expected stopped service")
    } catch {
      XCTAssertEqual(error as? DesktopTaskLifecycleError, .serviceStopped)
    }
  }

  func testAuthorizationIsFailClosedAndDoesNotReserve() async throws {
    let fixture = await Self.fixture(
      authorization: .denied,
      notificationDeliveryEnabled: true
    )
    let identity = Self.identity(sequence: 15)
    let state = await fixture.service.notificationState()
    XCTAssertTrue(state.isEnabled)
    XCTAssertEqual(state.authorization, .denied)
    do {
      _ = try await fixture.service.deliverCompletion(identity)
      XCTFail("Expected authorization failure")
    } catch {
      XCTAssertEqual(error as? DesktopTaskLifecycleError, .notificationNotAuthorized)
    }
    let deniedReserveCount = await fixture.store.reserveCount(for: identity)
    let deniedRequestCount = await fixture.notifications.requests().count
    XCTAssertEqual(deniedReserveCount, 0)
    XCTAssertEqual(deniedRequestCount, 0)

    await fixture.notifications.setAuthorization(.authorized)
    let requestedAuthorization = try await fixture.service.requestNotificationAuthorization()
    let authorizedDelivery = try await fixture.service.deliverCompletion(identity)
    XCTAssertEqual(requestedAuthorization, .authorized)
    XCTAssertEqual(authorizedDelivery, .delivered)
  }

  func testIdleSleepSettingTracksAuthoritativeActiveSetAndRollsBack() async throws {
    let fixture = await Self.fixture()
    var state = await fixture.service.idleSleepPreventionState()
    XCTAssertTrue(state.isEnabled)
    XCTAssertFalse(state.isActive)

    try await fixture.service.synchronizeActiveTaskIDs(["task-1"])
    try await fixture.service.synchronizeActiveTaskIDs(["task-1", "task-2"])
    XCTAssertEqual(fixture.idleSleep.counts(), Counts(begins: 1, ends: 0))
    try await fixture.service.setIdleSleepPreventionEnabled(false)
    state = await fixture.service.idleSleepPreventionState()
    XCTAssertFalse(state.isEnabled)
    XCTAssertFalse(state.isActive)
    XCTAssertEqual(state.activeTaskCount, 2)
    XCTAssertEqual(fixture.idleSleep.counts(), Counts(begins: 1, ends: 1))

    fixture.idleSleep.failNextBegin()
    do {
      try await fixture.service.setIdleSleepPreventionEnabled(true)
      XCTFail("Expected fail-closed assertion failure")
    } catch {
      XCTAssertEqual(error as? DesktopTaskLifecycleError, .idleSleepAssertionFailed)
    }
    state = await fixture.service.idleSleepPreventionState()
    XCTAssertFalse(state.isEnabled)
    try await fixture.service.setIdleSleepPreventionEnabled(true)
    state = await fixture.service.idleSleepPreventionState()
    XCTAssertTrue(state.isActive)
    try await fixture.service.synchronizeActiveTaskIDs([])
    XCTAssertEqual(fixture.idleSleep.counts(), Counts(begins: 2, ends: 2))
  }

  func testPowerEventsForwardSleepAndWakeWithoutClaimingRecovery() async throws {
    let fixture = await Self.fixture()
    let sleep = Task { await nextValue(from: fixture.service.powerEvents) }
    try await fixture.service.start()
    await fixture.powerSource.emit(.willSleep)
    let sleepEvent = await sleep.value
    XCTAssertEqual(sleepEvent, .willSleep)

    let wake = Task { await nextValue(from: fixture.service.powerEvents) }
    await fixture.powerSource.emit(.didWake)
    let wakeEvent = await wake.value
    let startCount = await fixture.powerSource.startCount
    XCTAssertEqual(wakeEvent, .didWake)
    XCTAssertEqual(startCount, 1)
    await fixture.service.shutdown()
    let stopCount = await fixture.powerSource.stopCount
    XCTAssertEqual(stopCount, 1)
  }

  func testRejectsZeroAndNegativeTerminalEventSequences() async {
    let fixture = await Self.fixture(notificationDeliveryEnabled: true)
    for sequence in [Int64(0), -1] {
      do {
        _ = try await fixture.service.deliverCompletion(Self.identity(sequence: sequence))
        XCTFail("Expected invalid EventStore sequence")
      } catch {
        XCTAssertEqual(error as? DesktopTaskLifecycleError, .invalidTerminalEventSequence)
      }
    }
    let requestCount = await fixture.notifications.requests().count
    XCTAssertEqual(requestCount, 0)
  }

  private struct Fixture {
    let service: DesktopTaskLifecycleService
    let notifications: FakeDesktopTaskNotifier
    let store: FakeDesktopTaskNotificationStore
    let idleSleep: FakeDesktopIdleSleepPreventer
    let powerSource: FakeDesktopPowerEventSource
  }

  @MainActor
  private static func fixture(
    store: FakeDesktopTaskNotificationStore = FakeDesktopTaskNotificationStore(),
    authorization: DesktopNotificationAuthorization = .authorized,
    notificationDeliveryEnabled: Bool = false
  ) -> Fixture {
    let notifications = FakeDesktopTaskNotifier(authorization: authorization)
    let idleSleep = FakeDesktopIdleSleepPreventer()
    let powerSource = FakeDesktopPowerEventSource()
    return Fixture(
      service: DesktopTaskLifecycleService(
        notifications: notifications,
        notificationStore: store,
        idleSleep: idleSleep,
        powerSource: powerSource,
        maximumActiveTasks: 8,
        maximumInFlightNotifications: 4,
        powerEventBufferLimit: 2,
        notificationDeliveryEnabled: notificationDeliveryEnabled
      ),
      notifications: notifications,
      store: store,
      idleSleep: idleSleep,
      powerSource: powerSource
    )
  }

  private static func identity(
    taskID: String = "task-1",
    sequence: Int64,
    kind: DesktopTaskTerminalNotificationKind = .completed
  ) -> DesktopTaskTerminalNotification {
    DesktopTaskTerminalNotification(
      taskID: taskID,
      terminalEventSequence: sequence,
      kind: kind
    )
  }
}

private actor FakeDesktopTaskNotifier: DesktopTaskNotificationDelivering {
  nonisolated let deliveryStarted: AsyncStream<Void>

  private let deliveryStartedContinuation: AsyncStream<Void>.Continuation
  private var currentAuthorization: DesktopNotificationAuthorization
  private var deliveredRequests: [DesktopTaskNotificationRequest] = []
  private var shouldBlockNextDelivery = false
  private var deliveryContinuation: CheckedContinuation<Void, Never>?

  init(authorization: DesktopNotificationAuthorization) {
    currentAuthorization = authorization
    let stream = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    deliveryStarted = stream.stream
    deliveryStartedContinuation = stream.continuation
  }

  func authorization() -> DesktopNotificationAuthorization {
    currentAuthorization
  }

  func requestAuthorization() -> DesktopNotificationAuthorization {
    currentAuthorization
  }

  func deliver(_ request: DesktopTaskNotificationRequest) async {
    deliveredRequests.append(request)
    guard shouldBlockNextDelivery else { return }
    shouldBlockNextDelivery = false
    _ = deliveryStartedContinuation.yield(())
    await withCheckedContinuation { deliveryContinuation = $0 }
  }

  func setAuthorization(_ authorization: DesktopNotificationAuthorization) {
    currentAuthorization = authorization
  }

  func blockNextDelivery() {
    shouldBlockNextDelivery = true
  }

  func releaseDelivery() {
    deliveryContinuation?.resume()
    deliveryContinuation = nil
  }

  func requests() -> [DesktopTaskNotificationRequest] {
    deliveredRequests
  }
}

private actor FakeDesktopTaskNotificationStore: DesktopTaskNotificationStore {
  nonisolated let reserveStarted: AsyncStream<Void>

  private enum State {
    case reserved
    case retry
    case scheduled
  }

  private struct Record {
    let requestIdentifier: String
    var state: State
    var reserves: Int
    var retries: Int
    var lastReservation: DesktopTaskNotificationReservation
  }

  private let reserveStartedContinuation: AsyncStream<Void>.Continuation
  private var records: [DesktopTaskTerminalNotification: Record] = [:]
  private var shouldFailNextMarkScheduled = false
  private var shouldBlockNextReserve = false
  private var reserveContinuation: CheckedContinuation<Void, Never>?

  init() {
    let stream = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    reserveStarted = stream.stream
    reserveStartedContinuation = stream.continuation
  }

  func reserve(
    _ identity: DesktopTaskTerminalNotification,
    requestIdentifier: String
  ) async throws -> DesktopTaskNotificationReservation {
    if shouldBlockNextReserve {
      shouldBlockNextReserve = false
      _ = reserveStartedContinuation.yield(())
      await withCheckedContinuation { reserveContinuation = $0 }
    }
    guard var record = records[identity] else {
      records[identity] = Record(
        requestIdentifier: requestIdentifier,
        state: .reserved,
        reserves: 1,
        retries: 0,
        lastReservation: .reserved
      )
      return .reserved
    }
    guard record.requestIdentifier == requestIdentifier else {
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
    record.reserves += 1
    switch record.state {
    case .scheduled:
      record.lastReservation = .scheduled
    case .reserved, .retry:
      record.lastReservation = .retry
    }
    records[identity] = record
    return record.lastReservation
  }

  func markRetry(
    _ identity: DesktopTaskTerminalNotification,
    requestIdentifier: String
  ) throws {
    guard var record = records[identity], record.requestIdentifier == requestIdentifier else {
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
    record.state = .retry
    record.retries += 1
    records[identity] = record
  }

  func markScheduled(
    _ identity: DesktopTaskTerminalNotification,
    requestIdentifier: String
  ) throws {
    guard var record = records[identity], record.requestIdentifier == requestIdentifier else {
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
    if shouldFailNextMarkScheduled {
      shouldFailNextMarkScheduled = false
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
    record.state = .scheduled
    records[identity] = record
  }

  func failNextMarkScheduled() {
    shouldFailNextMarkScheduled = true
  }

  func blockNextReserve() {
    shouldBlockNextReserve = true
  }

  func releaseReserve() {
    reserveContinuation?.resume()
    reserveContinuation = nil
  }

  func reserveCount(for identity: DesktopTaskTerminalNotification) -> Int {
    records[identity]?.reserves ?? 0
  }

  func retryCount(for identity: DesktopTaskTerminalNotification) -> Int {
    records[identity]?.retries ?? 0
  }

  func lastReservation(
    for identity: DesktopTaskTerminalNotification
  ) -> DesktopTaskNotificationReservation? {
    records[identity]?.lastReservation
  }
}

private struct Counts: Equatable {
  let begins: Int
  let ends: Int
}

private final class FakeDesktopIdleSleepPreventer: DesktopIdleSleepPreventing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var beginCount = 0
  private var endCount = 0
  private var active: Set<DesktopIdleSleepAssertion> = []
  private var shouldFailNextBegin = false

  func begin(reason _: String) throws -> DesktopIdleSleepAssertion {
    try lock.withLock {
      if shouldFailNextBegin {
        shouldFailNextBegin = false
        throw DesktopTaskLifecycleError.idleSleepAssertionFailed
      }
      beginCount += 1
      let assertion = DesktopIdleSleepAssertion()
      active.insert(assertion)
      return assertion
    }
  }

  func end(_ assertion: DesktopIdleSleepAssertion) {
    lock.withLock {
      guard active.remove(assertion) != nil else { return }
      endCount += 1
    }
  }

  func failNextBegin() {
    lock.withLock { shouldFailNextBegin = true }
  }

  func counts() -> Counts {
    lock.withLock { Counts(begins: beginCount, ends: endCount) }
  }
}

@MainActor
private final class FakeDesktopPowerEventSource: DesktopPowerEventSourcing {
  nonisolated let events: AsyncStream<DesktopPowerEvent>
  private let continuation: AsyncStream<DesktopPowerEvent>.Continuation
  private(set) var startCount = 0
  private(set) var stopCount = 0

  init() {
    let stream = AsyncStream.makeStream(
      of: DesktopPowerEvent.self,
      bufferingPolicy: .bufferingNewest(4)
    )
    events = stream.stream
    continuation = stream.continuation
  }

  func start() {
    startCount += 1
  }

  func stop() {
    stopCount += 1
  }

  func emit(_ event: DesktopPowerEvent) {
    _ = continuation.yield(event)
  }

  deinit {
    continuation.finish()
  }
}

private func nextValue<Element: Sendable>(from stream: AsyncStream<Element>) async -> Element? {
  var iterator = stream.makeAsyncIterator()
  return await iterator.next()
}

private func waitForStopping(_ service: DesktopTaskLifecycleService) async throws {
  for _ in 0..<1_000 {
    if await service.snapshot().isStopping { return }
    await Task.yield()
  }
  throw DesktopTaskLifecycleError.serviceStopped
}
