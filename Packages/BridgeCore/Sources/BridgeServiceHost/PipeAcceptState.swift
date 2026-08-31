#if os(Windows)
  import Foundation
  import WinSDK

  final class PipeAcceptState: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting: HANDLE = INVALID_HANDLE_VALUE
    private var cancelled = false

    func begin(_ handle: HANDLE) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !cancelled, accepting == INVALID_HANDLE_VALUE else { return false }
      accepting = handle
      return true
    }

    func finish(_ handle: HANDLE) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard accepting == handle else { return false }
      accepting = INVALID_HANDLE_VALUE
      return true
    }

    func cancel() -> HANDLE {
      lock.lock()
      defer { lock.unlock() }
      cancelled = true
      let handle = accepting
      accepting = INVALID_HANDLE_VALUE
      return handle
    }
  }
#endif
