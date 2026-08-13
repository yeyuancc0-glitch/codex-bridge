import BridgeCoordinator
import BridgeDomain
import BridgePersistence
import Foundation

protocol DesktopTaskProjectionReading: Sendable {
  func task(_ taskID: TaskID) async throws -> TaskProjection
  func reconcileActiveTasksAfterWake() async throws -> [TaskProjection]
}

extension TaskCoordinator: DesktopTaskProjectionReading {}

extension DesktopTaskProjectionReading {
  func reconcileActiveTasksAfterWake() async throws -> [TaskProjection] { [] }
}

protocol DesktopLifecycleConnectionControlling: Sendable {
  func suspendRemoteAdmissionsForSleep() async
  func revalidateRemoteAdmissionsAfterWake() async throws
  func waitForRemoteSubmissionDrain() async
}

extension DesktopConnectionRuntime: DesktopLifecycleConnectionControlling {}

actor DesktopTaskNotificationLedger: DesktopTaskNotificationStore {
  static let consumerID = "desktop.notifications.v1"

  private let store: EventStore
  private let ownerInstanceID: String

  init(store: EventStore, ownerInstanceID: String) {
    self.store = store
    self.ownerInstanceID = ownerInstanceID
  }

  func reserve(
    _ identity: DesktopTaskTerminalNotification,
    requestIdentifier: String
  ) async throws -> DesktopTaskNotificationReservation {
    guard requestIdentifier == Self.stableKey(for: identity),
      let reservation = try await store.notificationReservation(
        consumerID: Self.consumerID,
        stableKey: requestIdentifier
      )
    else { throw DesktopTaskLifecycleError.notificationStoreFailed }
    if reservation.state == .scheduled { return .scheduled }
    guard reservation.ownerInstanceID == ownerInstanceID,
      reservation.leaseUntil > Date()
    else { return .busy }
    return .reserved
  }

  func markRetry(
    _ identity: DesktopTaskTerminalNotification,
    requestIdentifier: String
  ) async throws {
    guard requestIdentifier == Self.stableKey(for: identity) else {
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
    try await store.releaseNotificationReservation(
      consumerID: Self.consumerID,
      stableKey: requestIdentifier,
      ownerInstanceID: ownerInstanceID
    )
  }

  func markScheduled(
    _ identity: DesktopTaskTerminalNotification,
    requestIdentifier: String
  ) async throws {
    guard requestIdentifier == Self.stableKey(for: identity) else {
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
    _ = try await store.markNotificationScheduled(
      consumerID: Self.consumerID,
      stableKey: requestIdentifier,
      ownerInstanceID: ownerInstanceID
    )
  }

  static func stableKey(for identity: DesktopTaskTerminalNotification) -> String {
    DesktopTaskLifecycleService.requestIdentifier(for: identity)
  }
}

actor DesktopTaskLifecycleCoordinator {
  private enum LifecycleState {
    case running
    case stopping
    case stopped
  }

  private static let maximumChangePagesPerDrain = 2
  private static let maximumActiveTasks = 2_048
  private let eventStore: EventStore
  private let coordinator: any DesktopTaskProjectionReading
  private let service: DesktopTaskLifecycleService
  private let connection: any DesktopLifecycleConnectionControlling
  private let ownerInstanceID: String
  private let pollInterval: Duration
  private var hintTask: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?
  private var powerTask: Task<Void, Never>?
  private var isDraining = false
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private var isChangingNotificationPreference = false
  private var isChangingIdleSleepPreference = false
  private var isRevalidatingWake = false
  private var lifecycleState = LifecycleState.running
  private var lifecycleGeneration: UInt64 = 0
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    eventStore: EventStore,
    coordinator: any DesktopTaskProjectionReading,
    service: DesktopTaskLifecycleService,
    connection: any DesktopLifecycleConnectionControlling,
    ownerInstanceID: String = UUID().uuidString.lowercased(),
    pollInterval: Duration = .seconds(2)
  ) {
    self.eventStore = eventStore
    self.coordinator = coordinator
    self.service = service
    self.connection = connection
    self.ownerInstanceID = ownerInstanceID
    self.pollInterval = pollInterval
  }

  func start() async throws {
    try requireRunning()
    try await service.start()
    try await synchronizePreferencesAndActiveTasks()
    await installObservers()
    try await refreshAfterTaskChange()
  }

  func synchronizePreferencesAndActiveTasks() async throws {
    let preferences = try await eventStore.lifecyclePreferences()
    await service.setNotificationDeliveryEnabled(preferences.notificationsEnabled)
    try await service.setIdleSleepPreventionEnabled(preferences.idleSleepEnabled)
    try await synchronizeActiveTasks()
  }

  func updateNotificationsEnabled(_ enabled: Bool) async throws {
    try requireRunning()
    guard !isChangingNotificationPreference else {
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
    isChangingNotificationPreference = true
    await waitForDrain()
    do {
      try requireRunning()
      if enabled {
        let authorization = try await service.requestNotificationAuthorization()
        guard authorization == .authorized else {
          throw DesktopTaskLifecycleError.notificationNotAuthorized
        }
        try requireRunning()
      }
      let consumerID = DesktopTaskNotificationLedger.consumerID
      let cursor = try await eventStore.notificationConsumerCursor(consumerID)
      _ = try await eventStore.setNotificationsEnabled(
        enabled,
        consumerID: consumerID,
        expectedCursor: cursor
      )
      await service.setNotificationDeliveryEnabled(enabled)
      isChangingNotificationPreference = false
      try? await drainChanges()
    } catch {
      isChangingNotificationPreference = false
      try? await drainChanges()
      throw error
    }
  }

  func updateIdleSleepEnabled(_ enabled: Bool) async throws {
    guard !isChangingIdleSleepPreference else {
      throw DesktopTaskLifecycleError.idleSleepAssertionFailed
    }
    isChangingIdleSleepPreference = true
    defer { isChangingIdleSleepPreference = false }
    if !enabled {
      try await eventStore.setIdleSleepEnabled(false)
      try await service.setIdleSleepPreventionEnabled(false)
      return
    }
    try await service.setIdleSleepPreventionEnabled(true)
    do {
      try await eventStore.setIdleSleepEnabled(true)
    } catch {
      try? await service.setIdleSleepPreventionEnabled(false)
      throw error
    }
  }

  func preferences() async throws -> LifecyclePreferences {
    try await eventStore.lifecyclePreferences()
  }

  func closeRemoteAdmissions() async {
    await connection.suspendRemoteAdmissionsForSleep()
    await connection.waitForRemoteSubmissionDrain()
  }

  func shutdown() async {
    switch lifecycleState {
    case .stopped:
      return
    case .stopping:
      await waitForShutdown()
      return
    case .running:
      lifecycleState = .stopping
      lifecycleGeneration &+= 1
    }
    await connection.suspendRemoteAdmissionsForSleep()
    await connection.waitForRemoteSubmissionDrain()
    await service.shutdown()
    hintTask?.cancel()
    pollTask?.cancel()
    powerTask?.cancel()
    await hintTask?.value
    await pollTask?.value
    await powerTask?.value
    hintTask = nil
    pollTask = nil
    powerTask = nil
    lifecycleState = .stopped
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  private func installObservers() async {
    let hints = await eventStore.taskChanges()
    hintTask = Task { [weak self, hints] in
      for await _ in hints {
        guard !Task.isCancelled else { return }
        try? await self?.refreshAfterTaskChange()
      }
    }
    let interval = pollInterval
    pollTask = Task { [weak self, interval] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: interval)
          try await self?.refreshAfterTaskChange()
        } catch is CancellationError {
          return
        } catch {
          continue
        }
      }
    }
    let powerEvents = service.powerEvents
    powerTask = Task { [weak self, powerEvents] in
      for await event in powerEvents {
        guard !Task.isCancelled else { return }
        await self?.handle(event)
      }
    }
  }

  private func refreshAfterTaskChange() async throws {
    guard lifecycleState == .running else { return }
    try await drainChanges()
    try await synchronizeActiveTasks()
  }

  private func drainChanges() async throws {
    guard !isDraining, lifecycleState == .running, !isChangingNotificationPreference else {
      return
    }
    isDraining = true
    defer { finishDrain() }
    let preferences = try await eventStore.lifecyclePreferences()
    let notificationsEnabled = preferences.notificationsEnabled
    guard notificationsEnabled else {
      try await fastForwardNotificationCursor()
      return
    }
    var cursor = try await eventStore.notificationConsumerCursor(
      DesktopTaskNotificationLedger.consumerID
    )
    var processedPages = 0
    while !Task.isCancelled, lifecycleState == .running,
      processedPages < Self.maximumChangePagesPerDrain
    {
      let changes = try await eventStore.changes(after: cursor, limit: 500)
      guard let through = changes.last?.changeID else { break }
      let candidates = try await notificationCandidates(
        from: changes,
        enabled: notificationsEnabled
      )
      let now = Date()
      let reservations = try await eventStore.reserveNotifications(
        consumerID: DesktopTaskNotificationLedger.consumerID,
        ownerInstanceID: ownerInstanceID,
        expectedCursor: cursor,
        throughChangeID: through,
        candidates: candidates,
        reservedAt: now,
        leaseUntil: now.addingTimeInterval(30)
      )
      await deliver(reservations)
      cursor = through
      processedPages += 1
    }
    if lifecycleState == .running, !Task.isCancelled {
      let now = Date()
      let pending = try await eventStore.claimPendingNotificationReservations(
        consumerID: DesktopTaskNotificationLedger.consumerID,
        ownerInstanceID: ownerInstanceID,
        now: now,
        leaseUntil: now.addingTimeInterval(30),
        allowOwnerTakeover: true,
        limit: 500
      )
      await deliver(pending)
    }
  }

  private func notificationCandidates(
    from changes: [TaskChange],
    enabled: Bool
  ) async throws -> [TaskNotificationCandidate] {
    guard enabled else { return [] }
    var result: [TaskNotificationCandidate] = []
    for change in changes where Self.mayBecomeTerminal(change.kind) {
      guard !Task.isCancelled, lifecycleState == .running else { break }
      let projection = try await coordinator.task(change.taskID)
      guard projection.lastSequence == change.eventSequence,
        let identity = Self.terminalIdentity(change: change, projection: projection)
      else { continue }
      result.append(
        TaskNotificationCandidate(
          stableKey: DesktopTaskNotificationLedger.stableKey(for: identity),
          change: change
        )
      )
    }
    return result
  }

  private func deliver(_ reservations: [TaskNotificationReservation]) async {
    for reservation in reservations where reservation.state == .reserved {
      guard !Task.isCancelled, lifecycleState == .running else { break }
      guard
        let projection = try? await coordinator.task(reservation.taskID),
        projection.lastSequence == reservation.eventSequence,
        let identity = Self.terminalIdentity(
          taskID: reservation.taskID,
          eventSequence: reservation.eventSequence,
          projection: projection
        ),
        DesktopTaskNotificationLedger.stableKey(for: identity) == reservation.stableKey
      else { continue }
      _ = try? await service.deliverCompletion(identity)
    }
  }

  private func synchronizeActiveTasks() async throws {
    var cursor: TaskID?
    var taskIDs = Set<String>()
    while true {
      let page = try await eventStore.taskIDsWithActiveSnapshots(
        afterTaskID: cursor,
        limit: 500
      )
      guard taskIDs.count <= Self.maximumActiveTasks - page.count else {
        throw DesktopTaskLifecycleError.tooManyActiveTasks(maximum: Self.maximumActiveTasks)
      }
      taskIDs.formUnion(page.map(\.rawValue))
      guard page.count == 500 else { break }
      cursor = page.last
    }
    try await service.synchronizeActiveTaskIDs(taskIDs)
    _ = try? await eventStore.pruneNotificationHistory(limit: 500)
  }

  private func waitForDrain() async {
    guard isDraining else { return }
    await withCheckedContinuation { drainWaiters.append($0) }
  }

  private func finishDrain() {
    isDraining = false
    let waiters = drainWaiters
    drainWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  private func handle(_ event: DesktopPowerEvent) async {
    guard lifecycleState == .running else { return }
    switch event {
    case .willSleep:
      await connection.suspendRemoteAdmissionsForSleep()
      guard lifecycleState == .running else { return }
      await connection.waitForRemoteSubmissionDrain()
    case .didWake:
      guard !isRevalidatingWake else { return }
      let generation = lifecycleGeneration
      isRevalidatingWake = true
      defer { isRevalidatingWake = false }
      do {
        _ = try await coordinator.reconcileActiveTasksAfterWake()
        guard isCurrent(generation) else { return }
        try await refreshAfterTaskChange()
        guard isCurrent(generation) else { return }
        try await connection.revalidateRemoteAdmissionsAfterWake()
        guard isCurrent(generation) else {
          await connection.suspendRemoteAdmissionsForSleep()
          return
        }
      } catch {
        await connection.suspendRemoteAdmissionsForSleep()
      }
    }
  }

  private func fastForwardNotificationCursor() async throws {
    let consumerID = DesktopTaskNotificationLedger.consumerID
    let cursor = try await eventStore.notificationConsumerCursor(consumerID)
    let head = try await eventStore.taskChangeHead()
    guard head > cursor else { return }
    _ = try await eventStore.fastForwardNotificationConsumer(
      consumerID: consumerID,
      expectedCursor: cursor,
      throughChangeID: head,
      at: Date()
    )
  }

  private func waitForShutdown() async {
    guard lifecycleState != .stopped else { return }
    await withCheckedContinuation { shutdownWaiters.append($0) }
  }

  private func requireRunning() throws {
    guard lifecycleState == .running else {
      throw DesktopTaskLifecycleError.serviceStopped
    }
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    lifecycleState == .running && lifecycleGeneration == generation
  }

  private static func mayBecomeTerminal(_ kind: String) -> Bool {
    switch kind {
    case "task.completionRecorded", "task.failureRecorded", "task.turnStopped",
      "task.localApprovalResolved", "task.recoveryResolved":
      true
    default:
      false
    }
  }

  private static func terminalIdentity(
    change: TaskChange,
    projection: TaskProjection
  ) -> DesktopTaskTerminalNotification? {
    terminalIdentity(
      taskID: change.taskID,
      eventSequence: change.eventSequence,
      projection: projection
    )
  }

  private static func terminalIdentity(
    taskID: TaskID,
    eventSequence: Int64,
    projection: TaskProjection
  ) -> DesktopTaskTerminalNotification? {
    let kind: DesktopTaskTerminalNotificationKind
    switch projection.aggregate.phase {
    case .completed:
      kind = .completed
    case .failed:
      kind = .failed
    case .interrupted, .rejected:
      kind = .cancelled
    default:
      return nil
    }
    return DesktopTaskTerminalNotification(
      taskID: taskID.rawValue,
      terminalEventSequence: eventSequence,
      kind: kind
    )
  }
}
