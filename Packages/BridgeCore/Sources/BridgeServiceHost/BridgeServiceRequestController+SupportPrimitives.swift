import BridgeDomain
import Foundation

struct StreamRegistration: Sendable {
  let forwarder: Task<Void, Never>
  let subscriptionID: Int
}

final class StreamRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var registrations: [TaskID: StreamRegistration] = [:]

  func take(_ taskID: TaskID) -> StreamRegistration? {
    lock.lock()
    defer { lock.unlock() }
    return registrations.removeValue(forKey: taskID)
  }

  func take(_ taskID: TaskID, subscriptionID: Int) -> StreamRegistration? {
    lock.lock()
    defer { lock.unlock() }
    guard registrations[taskID]?.subscriptionID == subscriptionID else { return nil }
    return registrations.removeValue(forKey: taskID)
  }

  @discardableResult
  func install(taskID: TaskID, registration: StreamRegistration) -> StreamRegistration? {
    lock.lock()
    let previous = registrations.updateValue(registration, forKey: taskID)
    lock.unlock()
    return previous
  }

  func takeAll() -> [TaskID: StreamRegistration] {
    lock.lock()
    defer { lock.unlock() }
    let active = registrations
    registrations.removeAll(keepingCapacity: false)
    return active
  }

  func count() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return registrations.count
  }
}

final class AsyncMutex: @unchecked Sendable {
  private let stateLock = NSLock()
  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    await withCheckedContinuation { continuation in
      stateLock.lock()
      if locked {
        waiters.append(continuation)
        stateLock.unlock()
        return
      }
      locked = true
      stateLock.unlock()
      continuation.resume()
    }
  }

  func release() {
    stateLock.lock()
    let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
    if waiter == nil { locked = false }
    stateLock.unlock()
    waiter?.resume()
  }
}

final class XPCRequestAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumConcurrent: Int
  private var active = 0

  init(maximumConcurrent: Int) {
    precondition(maximumConcurrent > 0)
    self.maximumConcurrent = maximumConcurrent
  }

  func acquire() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard active < maximumConcurrent else { return false }
    active += 1
    return true
  }

  func release() {
    lock.lock()
    defer { lock.unlock() }
    active -= 1
  }
}

final class XPCReplyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var reply: ((Data) -> Void)?

  init(_ reply: @escaping (Data) -> Void) {
    self.reply = reply
  }

  func call(_ data: Data) {
    lock.lock()
    let callback = reply
    reply = nil
    lock.unlock()
    callback?(data)
  }
}
