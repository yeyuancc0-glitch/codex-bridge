@preconcurrency import AppKit
import BridgeSecurity
import CryptoKit
import Foundation
@preconcurrency import UserNotifications

public enum DesktopNotificationAuthorization: Equatable, Sendable {
  case notDetermined
  case denied
  case authorized

  var permitsDelivery: Bool { self == .authorized }
}

public enum DesktopTaskTerminalNotificationKind: String, CaseIterable, Sendable {
  case completed
  case failed
  case cancelled
}

public struct DesktopTaskTerminalNotification: Equatable, Hashable, Sendable {
  public let taskID: String
  public let terminalEventSequence: Int64
  public let kind: DesktopTaskTerminalNotificationKind

  public init(
    taskID: String,
    terminalEventSequence: Int64,
    kind: DesktopTaskTerminalNotificationKind
  ) {
    self.taskID = taskID
    self.terminalEventSequence = terminalEventSequence
    self.kind = kind
  }
}

public struct DesktopTaskNotificationRoute: Equatable, Sendable {
  private static let versionKey = "codex_bridge_route_version"
  private static let taskIDKey = "codex_bridge_task_id"
  private static let eventSequenceKey = "codex_bridge_terminal_event_sequence"
  private static let kindKey = "codex_bridge_terminal_kind"
  private static let currentVersion = "1"

  public let taskID: String
  public let terminalEventSequence: Int64
  public let kind: DesktopTaskTerminalNotificationKind

  public init?(identity: DesktopTaskTerminalNotification) {
    guard Self.validTaskIdentifier(identity.taskID), identity.terminalEventSequence > 0 else {
      return nil
    }
    taskID = identity.taskID
    terminalEventSequence = identity.terminalEventSequence
    kind = identity.kind
  }

  public init?(userInfo: [AnyHashable: Any]) {
    guard userInfo[Self.versionKey] as? String == Self.currentVersion,
      let taskID = userInfo[Self.taskIDKey] as? String,
      let sequenceValue = userInfo[Self.eventSequenceKey] as? String,
      let sequence = Int64(sequenceValue),
      String(sequence) == sequenceValue,
      let kindValue = userInfo[Self.kindKey] as? String,
      let kind = DesktopTaskTerminalNotificationKind(rawValue: kindValue),
      Self.validTaskIdentifier(taskID), sequence > 0
    else { return nil }
    self.taskID = taskID
    terminalEventSequence = sequence
    self.kind = kind
  }

  public var userInfo: [AnyHashable: Any] {
    [
      Self.versionKey: Self.currentVersion,
      Self.taskIDKey: taskID,
      Self.eventSequenceKey: String(terminalEventSequence),
      Self.kindKey: kind.rawValue,
    ]
  }

  fileprivate static func validTaskIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && value.utf8.count <= 256 && value.rangeOfCharacter(from: .controlCharacters) == nil
      && OutboundContentSecurity.isSafe(value)
  }
}

public struct DesktopTaskNotificationRequest: Equatable, Sendable {
  public let identity: DesktopTaskTerminalNotification
  public let requestIdentifier: String
  public let title: String
  public let body: String

  fileprivate init(
    identity: DesktopTaskTerminalNotification,
    requestIdentifier: String,
    title: String,
    body: String
  ) {
    self.identity = identity
    self.requestIdentifier = requestIdentifier
    self.title = title
    self.body = body
  }
}

public enum DesktopTaskNotificationReservation: Equatable, Sendable {
  case reserved
  case retry
  case busy
  case scheduled
}

public enum DesktopTaskCompletionDelivery: Equatable, Sendable {
  case delivered
  case duplicate
  case inProgress
  case disabled
}

public enum DesktopPowerEvent: Equatable, Sendable {
  case willSleep
  case didWake
}

public struct DesktopIdleSleepAssertion: Equatable, Hashable, Sendable {
  fileprivate let id: UUID

  public init() {
    id = UUID()
  }
}

public enum DesktopTaskLifecycleError: Error, Equatable, Sendable {
  case invalidTaskIdentifier
  case invalidTerminalEventSequence
  case invalidNotificationContent
  case tooManyActiveTasks(maximum: Int)
  case tooManyInFlightNotifications(maximum: Int)
  case notificationNotAuthorized
  case notificationDeliveryFailed
  case notificationStoreFailed
  case idleSleepAssertionFailed
  case serviceStopped
}

public protocol DesktopTaskNotificationDelivering: Sendable {
  func authorization() async -> DesktopNotificationAuthorization
  func requestAuthorization() async throws -> DesktopNotificationAuthorization
  func containsRequest(identifier: String) async -> Bool
  func deliver(_ request: DesktopTaskNotificationRequest) async throws
}

extension DesktopTaskNotificationDelivering {
  public func containsRequest(identifier _: String) async -> Bool { false }
}

public protocol DesktopTaskNotificationStore: Sendable {
  func reserve(
    _ identity: DesktopTaskTerminalNotification,
    requestIdentifier: String
  ) async throws -> DesktopTaskNotificationReservation
  func markRetry(
    _ identity: DesktopTaskTerminalNotification,
    requestIdentifier: String
  ) async throws
  func markScheduled(
    _ identity: DesktopTaskTerminalNotification,
    requestIdentifier: String
  ) async throws
}

public protocol DesktopIdleSleepPreventing: Sendable {
  func begin(reason: String) throws -> DesktopIdleSleepAssertion
  func end(_ assertion: DesktopIdleSleepAssertion)
}

public protocol DesktopPowerEventSourcing: Sendable {
  var events: AsyncStream<DesktopPowerEvent> { get }
  @MainActor func start()
  @MainActor func stop()
}

public struct DesktopTaskLifecycleSnapshot: Equatable, Sendable {
  public let activeTaskCount: Int
  public let isPreventingIdleSleep: Bool
  public let inFlightNotificationCount: Int
  public let notificationDeliveryEnabled: Bool
  public let idleSleepPreventionEnabled: Bool
  public let isStarted: Bool
  public let isStopping: Bool
}

public struct DesktopTaskNotificationState: Equatable, Sendable {
  public let isEnabled: Bool
  public let authorization: DesktopNotificationAuthorization
}

public struct DesktopIdleSleepPreventionState: Equatable, Sendable {
  public let isEnabled: Bool
  public let isActive: Bool
  public let activeTaskCount: Int
}

public actor DesktopTaskLifecycleService {
  public nonisolated let powerEvents: AsyncStream<DesktopPowerEvent>

  private enum ShutdownState {
    case running
    case stopping
    case stopped
  }

  private let notifications: any DesktopTaskNotificationDelivering
  private let notificationStore: any DesktopTaskNotificationStore
  private let idleSleep: any DesktopIdleSleepPreventing
  private let powerSource: any DesktopPowerEventSourcing
  private let powerContinuation: AsyncStream<DesktopPowerEvent>.Continuation
  private let maximumActiveTasks: Int
  private let maximumInFlightNotifications: Int
  private var activeTaskIDs: Set<String> = []
  private var idleSleepAssertion: DesktopIdleSleepAssertion?
  private var pendingNotifications: Set<DesktopTaskTerminalNotification> = []
  private var inFlightNotificationCount = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
  private var powerForwarder: Task<Void, Never>?
  private var notificationDeliveryEnabled: Bool
  private var idleSleepPreventionEnabled: Bool
  private var started = false
  private var shutdownState = ShutdownState.running

  public init(
    notifications: any DesktopTaskNotificationDelivering,
    notificationStore: any DesktopTaskNotificationStore,
    idleSleep: any DesktopIdleSleepPreventing,
    powerSource: any DesktopPowerEventSourcing,
    maximumActiveTasks: Int = 2_048,
    maximumInFlightNotifications: Int = 64,
    powerEventBufferLimit: Int = 16,
    notificationDeliveryEnabled: Bool = false,
    idleSleepPreventionEnabled: Bool = true
  ) {
    let stream = AsyncStream.makeStream(
      of: DesktopPowerEvent.self,
      bufferingPolicy: .bufferingNewest(max(1, powerEventBufferLimit))
    )
    self.notifications = notifications
    self.notificationStore = notificationStore
    self.idleSleep = idleSleep
    self.powerSource = powerSource
    powerEvents = stream.stream
    powerContinuation = stream.continuation
    self.maximumActiveTasks = max(1, maximumActiveTasks)
    self.maximumInFlightNotifications = max(1, maximumInFlightNotifications)
    self.notificationDeliveryEnabled = notificationDeliveryEnabled
    self.idleSleepPreventionEnabled = idleSleepPreventionEnabled
  }

  public func start() async throws {
    try requireRunning()
    guard !started else { return }
    started = true
    await powerSource.start()
    let sourceEvents = powerSource.events
    powerForwarder = Task { [weak self] in
      for await event in sourceEvents {
        guard let self else { return }
        await self.receive(event)
      }
    }
  }

  public func synchronizeActiveTaskIDs(_ taskIDs: Set<String>) throws {
    try requireRunning()
    try Self.validate(taskIDs: taskIDs, maximumCount: maximumActiveTasks)
    activeTaskIDs = taskIDs
    if idleSleepPreventionEnabled, !taskIDs.isEmpty, idleSleepAssertion == nil {
      do {
        idleSleepAssertion = try idleSleep.begin(
          reason: "Codex Bridge is executing active local tasks."
        )
      } catch {
        throw DesktopTaskLifecycleError.idleSleepAssertionFailed
      }
    }
    if taskIDs.isEmpty {
      endIdleSleepAssertion()
    }
  }

  public func setIdleSleepPreventionEnabled(_ enabled: Bool) throws {
    try requireRunning()
    guard enabled != idleSleepPreventionEnabled else { return }
    if !enabled {
      idleSleepPreventionEnabled = false
      endIdleSleepAssertion()
      return
    }
    guard !activeTaskIDs.isEmpty else {
      idleSleepPreventionEnabled = true
      return
    }
    do {
      idleSleepAssertion = try idleSleep.begin(
        reason: "Codex Bridge is executing active local tasks."
      )
      idleSleepPreventionEnabled = true
    } catch {
      idleSleepAssertion = nil
      idleSleepPreventionEnabled = false
      throw DesktopTaskLifecycleError.idleSleepAssertionFailed
    }
  }

  public func idleSleepPreventionState() -> DesktopIdleSleepPreventionState {
    DesktopIdleSleepPreventionState(
      isEnabled: idleSleepPreventionEnabled,
      isActive: idleSleepAssertion != nil,
      activeTaskCount: activeTaskIDs.count
    )
  }

  public func notificationAuthorization() async -> DesktopNotificationAuthorization {
    await notifications.authorization()
  }

  public func setNotificationDeliveryEnabled(_ enabled: Bool) {
    guard shutdownState == .running else { return }
    notificationDeliveryEnabled = enabled
  }

  public func notificationState() async -> DesktopTaskNotificationState {
    DesktopTaskNotificationState(
      isEnabled: notificationDeliveryEnabled,
      authorization: await notifications.authorization()
    )
  }

  public func requestNotificationAuthorization() async throws -> DesktopNotificationAuthorization {
    try requireRunning()
    return try await notifications.requestAuthorization()
  }

  public func deliverCompletion(
    _ identity: DesktopTaskTerminalNotification
  ) async throws -> DesktopTaskCompletionDelivery {
    try requireRunning()
    try Self.validate(identity)
    guard notificationDeliveryEnabled else { return .disabled }
    guard !pendingNotifications.contains(identity) else { return .inProgress }
    guard inFlightNotificationCount < maximumInFlightNotifications else {
      throw DesktopTaskLifecycleError.tooManyInFlightNotifications(
        maximum: maximumInFlightNotifications
      )
    }
    pendingNotifications.insert(identity)
    inFlightNotificationCount += 1
    defer { finishNotificationOperation(identity) }
    return try await scheduleNotification(identity)
  }

  public func snapshot() -> DesktopTaskLifecycleSnapshot {
    DesktopTaskLifecycleSnapshot(
      activeTaskCount: activeTaskIDs.count,
      isPreventingIdleSleep: idleSleepAssertion != nil,
      inFlightNotificationCount: inFlightNotificationCount,
      notificationDeliveryEnabled: notificationDeliveryEnabled,
      idleSleepPreventionEnabled: idleSleepPreventionEnabled,
      isStarted: started && shutdownState == .running,
      isStopping: shutdownState == .stopping
    )
  }

  public func shutdown() async {
    switch shutdownState {
    case .stopped:
      return
    case .stopping:
      await waitForShutdown()
      return
    case .running:
      shutdownState = .stopping
    }
    powerForwarder?.cancel()
    powerForwarder = nil
    if inFlightNotificationCount > 0 {
      await withCheckedContinuation { drainWaiters.append($0) }
    }
    if started {
      await powerSource.stop()
    }
    started = false
    powerContinuation.finish()
    activeTaskIDs.removeAll(keepingCapacity: false)
    endIdleSleepAssertion()
    shutdownState = .stopped
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  private func scheduleNotification(
    _ identity: DesktopTaskTerminalNotification
  ) async throws -> DesktopTaskCompletionDelivery {
    let request = try Self.makeRequest(for: identity)
    guard await notifications.authorization().permitsDelivery else {
      throw DesktopTaskLifecycleError.notificationNotAuthorized
    }
    try requireRunning()
    let reservation: DesktopTaskNotificationReservation
    do {
      reservation = try await notificationStore.reserve(
        identity,
        requestIdentifier: request.requestIdentifier
      )
    } catch {
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
    switch reservation {
    case .scheduled:
      return .duplicate
    case .busy:
      return .inProgress
    case .reserved, .retry:
      break
    }
    if await notifications.containsRequest(identifier: request.requestIdentifier) {
      do {
        try await notificationStore.markScheduled(
          identity,
          requestIdentifier: request.requestIdentifier
        )
      } catch {
        throw DesktopTaskLifecycleError.notificationStoreFailed
      }
      return .duplicate
    }
    guard shutdownState == .running else {
      try await markRetry(request)
      throw DesktopTaskLifecycleError.serviceStopped
    }
    do {
      try await notifications.deliver(request)
    } catch {
      try await markRetry(request)
      throw DesktopTaskLifecycleError.notificationDeliveryFailed
    }
    do {
      try await notificationStore.markScheduled(
        identity,
        requestIdentifier: request.requestIdentifier
      )
    } catch {
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
    return .delivered
  }

  private func markRetry(_ request: DesktopTaskNotificationRequest) async throws {
    do {
      try await notificationStore.markRetry(
        request.identity,
        requestIdentifier: request.requestIdentifier
      )
    } catch {
      throw DesktopTaskLifecycleError.notificationStoreFailed
    }
  }

  private func finishNotificationOperation(_ identity: DesktopTaskTerminalNotification) {
    pendingNotifications.remove(identity)
    inFlightNotificationCount -= 1
    guard inFlightNotificationCount == 0 else { return }
    let waiters = drainWaiters
    drainWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters { waiter.resume() }
  }

  private func waitForShutdown() async {
    guard shutdownState != .stopped else { return }
    await withCheckedContinuation { shutdownWaiters.append($0) }
  }

  private func receive(_ event: DesktopPowerEvent) {
    guard shutdownState == .running else { return }
    _ = powerContinuation.yield(event)
  }

  private func endIdleSleepAssertion() {
    guard let assertion = idleSleepAssertion else { return }
    idleSleepAssertion = nil
    idleSleep.end(assertion)
  }

  private func requireRunning() throws {
    guard shutdownState == .running else {
      throw DesktopTaskLifecycleError.serviceStopped
    }
  }

  private static func makeRequest(
    for identity: DesktopTaskTerminalNotification
  ) throws -> DesktopTaskNotificationRequest {
    let content: (title: String, body: String)
    switch identity.kind {
    case .completed:
      content = ("任务已完成", "Codex Bridge 已保存任务的最终报告。")
    case .failed:
      content = ("任务未完成", "Codex Bridge 已记录任务失败状态。")
    case .cancelled:
      content = ("任务已停止", "Codex Bridge 已记录任务停止状态。")
    }
    let title = OutboundContentSecurity.redacted(content.title, maximumUTF8Bytes: 128)
    let body = OutboundContentSecurity.redacted(content.body, maximumUTF8Bytes: 512)
    guard OutboundContentSecurity.isSafe(title), OutboundContentSecurity.isSafe(body) else {
      throw DesktopTaskLifecycleError.invalidNotificationContent
    }
    return DesktopTaskNotificationRequest(
      identity: identity,
      requestIdentifier: requestIdentifier(for: identity),
      title: title,
      body: body
    )
  }

  static func requestIdentifier(
    for identity: DesktopTaskTerminalNotification
  ) -> String {
    let digest = SHA256.hash(data: Data(identity.taskID.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    return "codex-bridge.task.\(digest).\(identity.terminalEventSequence).\(identity.kind.rawValue)"
  }

  private static func validate(taskIDs: Set<String>, maximumCount: Int) throws {
    guard taskIDs.count <= maximumCount else {
      throw DesktopTaskLifecycleError.tooManyActiveTasks(maximum: maximumCount)
    }
    guard taskIDs.allSatisfy(validIdentifier) else {
      throw DesktopTaskLifecycleError.invalidTaskIdentifier
    }
  }

  private static func validate(_ identity: DesktopTaskTerminalNotification) throws {
    guard validIdentifier(identity.taskID) else {
      throw DesktopTaskLifecycleError.invalidTaskIdentifier
    }
    guard identity.terminalEventSequence > 0 else {
      throw DesktopTaskLifecycleError.invalidTerminalEventSequence
    }
  }

  private static func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && value.utf8.count <= 256 && value.rangeOfCharacter(from: .controlCharacters) == nil
  }
}

public final class ProcessInfoDesktopIdleSleepPreventer: DesktopIdleSleepPreventing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var activities: [DesktopIdleSleepAssertion: NSObjectProtocol] = [:]

  public init() {}

  public func begin(reason: String) throws -> DesktopIdleSleepAssertion {
    guard !reason.isEmpty else { throw DesktopTaskLifecycleError.idleSleepAssertionFailed }
    let assertion = DesktopIdleSleepAssertion()
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
      reason: reason
    )
    lock.withLock {
      activities[assertion] = activity
    }
    return assertion
  }

  public func end(_ assertion: DesktopIdleSleepAssertion) {
    let activity = lock.withLock {
      activities.removeValue(forKey: assertion)
    }
    guard let activity else { return }
    ProcessInfo.processInfo.endActivity(activity)
  }
}

public struct UserNotificationDesktopTaskNotifier: DesktopTaskNotificationDelivering {
  public init() {}

  public func authorization() async -> DesktopNotificationAuthorization {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return .authorized
    case .denied:
      return .denied
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .denied
    }
  }

  public func requestAuthorization() async throws -> DesktopNotificationAuthorization {
    _ = try await UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound]
    )
    return await authorization()
  }

  public func deliver(_ request: DesktopTaskNotificationRequest) async throws {
    guard await authorization().permitsDelivery else {
      throw DesktopTaskLifecycleError.notificationNotAuthorized
    }
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.sound = .default
    if let route = DesktopTaskNotificationRoute(identity: request.identity) {
      content.userInfo = route.userInfo
    }
    let notification = UNNotificationRequest(
      identifier: request.requestIdentifier,
      content: content,
      trigger: nil
    )
    try await UNUserNotificationCenter.current().add(notification)
  }

  public func containsRequest(identifier: String) async -> Bool {
    let center = UNUserNotificationCenter.current()
    let pending = await center.pendingNotificationRequests()
    if pending.contains(where: { $0.identifier == identifier }) { return true }
    let deliveredIdentifiers: [String] = await withCheckedContinuation { continuation in
      center.getDeliveredNotifications { notifications in
        continuation.resume(returning: notifications.map(\.request.identifier))
      }
    }
    return deliveredIdentifiers.contains(identifier)
  }
}

@MainActor
public final class WorkspaceDesktopPowerEventSource: DesktopPowerEventSourcing {
  public nonisolated let events: AsyncStream<DesktopPowerEvent>

  private let continuation: AsyncStream<DesktopPowerEvent>.Continuation
  private let synchronousWillSleep: @Sendable () -> Void
  private var observers: [NSObjectProtocol] = []

  public init(
    bufferLimit: Int = 16,
    synchronousWillSleep: @escaping @Sendable () -> Void = {}
  ) {
    let stream = AsyncStream.makeStream(
      of: DesktopPowerEvent.self,
      bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
    )
    events = stream.stream
    continuation = stream.continuation
    self.synchronousWillSleep = synchronousWillSleep
  }

  public func start() {
    guard observers.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter
    observers = [
      center.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { [continuation, synchronousWillSleep] _ in
        synchronousWillSleep()
        _ = continuation.yield(.willSleep)
      },
      center.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [continuation] _ in
        _ = continuation.yield(.didWake)
      },
    ]
  }

  public func stop() {
    let center = NSWorkspace.shared.notificationCenter
    for observer in observers { center.removeObserver(observer) }
    observers.removeAll(keepingCapacity: false)
  }

  deinit {
    continuation.finish()
  }
}
