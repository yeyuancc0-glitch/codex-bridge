import Foundation

public struct ManagedProcessIdentity: Codable, Equatable, Sendable {
  public let pid: Int32
  public let startTimeMicros: Int64
  public let processGroupID: Int32

  public init(pid: Int32, startTimeMicros: Int64, processGroupID: Int32) {
    self.pid = pid
    self.startTimeMicros = startTimeMicros
    self.processGroupID = processGroupID
  }
}

public enum ManagedProcessTermination: Equatable, Sendable {
  case exited(Int32)
  case killed(Int32)
  case notStarted
}

public enum ManagedProcessError: Error, Equatable, Sendable {
  case invalidArgument
  case processLaunchFailed(Int32)
  case stdinUnavailable
}

public struct ManagedProcessResult: Equatable, Sendable {
  public let termination: ManagedProcessTermination
  public let timedOut: Bool

  public init(termination: ManagedProcessTermination, timedOut: Bool) {
    self.termination = termination
    self.timedOut = timedOut
  }
}

public struct BoundedProcessOutput: Equatable, Sendable {
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

public final class BoundedProcessOutputCollector: @unchecked Sendable {
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
      headStorage.append(data.prefix(headLimit - headStorage.count))
    }

    if data.count >= maximumBytes {
      tailStorage = Data(data.suffix(maximumBytes))
    } else {
      tailStorage.append(data)
      if tailStorage.count > maximumBytes {
        tailStorage = Data(tailStorage.suffix(maximumBytes))
      }
    }

    let (nextCount, overflow) = totalByteCount.addingReportingOverflow(data.count)
    totalByteCount = overflow ? Int.max : nextCount
    overflowed = overflowed || totalByteCount > maximumBytes
  }

  public func snapshot() -> BoundedProcessOutput {
    lock.lock()
    defer { lock.unlock() }
    return BoundedProcessOutput(
      head: String(decoding: headStorage, as: UTF8.self),
      tail: String(
        decoding: tailStorage.suffix(min(maximumBytes, Self.maximumTailBytes)),
        as: UTF8.self
      ),
      byteCount: min(totalByteCount, maximumBytes),
      truncated: overflowed
    )
  }
}

