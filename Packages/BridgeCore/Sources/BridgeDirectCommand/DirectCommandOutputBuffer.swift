import Foundation

public struct DirectCommandOutputBuffer: Equatable, Sendable {
  public let head: String
  public let tail: String
  public let byteCount: Int
  public let truncated: Bool

  public init(head: String, tail: String, byteCount: Int, truncated: Bool) {
    self.head = head
    self.tail = tail
    self.byteCount = byteCount
    self.truncated = truncated
  }
}

public final class DirectCommandOutputCollector: @unchecked Sendable {
  public let maximumBytes: Int
  private let lock = NSLock()
  private var storage = Data()
  private var overflowed = false

  public init(maximumBytes: Int = 1_048_576) {
    self.maximumBytes = max(1, maximumBytes)
  }

  public func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard !overflowed else { return }
    if storage.count + data.count > maximumBytes {
      storage.append(data)
      storage = storage.suffix(maximumBytes)
      overflowed = true
      return
    }
    storage.append(data)
  }

  public func snapshot() -> DirectCommandOutputBuffer {
    lock.lock()
    defer { lock.unlock() }
    let bounded = storage.suffix(maximumBytes)
    let text = String(decoding: bounded, as: UTF8.self)
    let headLength = min(text.count, 4_096)
    let tailLength = min(text.count, 32 * 1_024)
    let head = String(text.prefix(headLength))
    let tail = String(text.suffix(tailLength))
    return DirectCommandOutputBuffer(
      head: head,
      tail: tail,
      byteCount: bounded.count,
      truncated: overflowed
    )
  }

  public var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storage.isEmpty
  }
}
