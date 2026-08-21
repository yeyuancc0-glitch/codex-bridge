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
  private var headStorage = Data()
  private var tailStorage = Data()
  private var totalByteCount = 0
  private var overflowed = false
  private static let maximumHeadBytes = 4 * 1_024
  private static let maximumTailBytes = 32 * 1_024

  public init(maximumBytes: Int = 1_048_576) {
    self.maximumBytes = max(1, maximumBytes)
  }

  public func append(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }

    let headLimit = min(maximumBytes, Self.maximumHeadBytes)
    if headStorage.count < headLimit {
      let remaining = headLimit - headStorage.count
      headStorage.append(data.prefix(remaining))
    }

    if data.count >= maximumBytes {
      tailStorage = Data(data.suffix(maximumBytes))
    } else {
      tailStorage.append(data)
      if tailStorage.count > maximumBytes {
        tailStorage = Data(tailStorage.suffix(maximumBytes))
      }
    }

    let (nextCount, didOverflow) = totalByteCount.addingReportingOverflow(data.count)
    totalByteCount = didOverflow ? Int.max : nextCount
    overflowed = overflowed || totalByteCount > maximumBytes
  }

  public func snapshot() -> DirectCommandOutputBuffer {
    lock.lock()
    defer { lock.unlock() }
    let head = String(decoding: headStorage, as: UTF8.self)
    let tail = String(
      decoding: tailStorage.suffix(min(maximumBytes, Self.maximumTailBytes)), as: UTF8.self)
    return DirectCommandOutputBuffer(
      head: head,
      tail: tail,
      byteCount: min(totalByteCount, maximumBytes),
      truncated: overflowed
    )
  }

  public var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return totalByteCount == 0
  }
}
