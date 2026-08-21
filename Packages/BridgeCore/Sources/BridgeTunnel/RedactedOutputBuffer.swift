import Foundation

final class RedactedOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private let patterns: [(Data, Data)]
  private let retainedTailBytes: Int
  private let authenticationMarkers = [
    Array("unauthorized".utf8),
    Array("forbidden".utf8),
    Array("\"status\":401".utf8),
    Array("\"status\":403".utf8),
    Array("\"status\":\"401\"".utf8),
    Array("\"status\":\"403\"".utf8),
    Array("\"status_code\":401".utf8),
    Array("\"status_code\":403".utf8),
    Array("\"status_code\":\"401\"".utf8),
    Array("\"status_code\":\"403\"".utf8),
  ]
  private var pending = Data()
  private var output = Data()
  private var truncated = false
  private var authenticationTail: [UInt8] = []
  private var authenticationFailure = false

  init(limit: Int, sensitiveValues: [String]) {
    self.limit = limit
    let uniqueValues = Set(sensitiveValues.filter { !$0.isEmpty })
    patterns = uniqueValues.sorted { $0.utf8.count > $1.utf8.count }.map {
      (Data($0.utf8), Data("<redacted>".utf8))
    }
    retainedTailBytes = patterns.map(\.0.count).max() ?? 0
  }

  func append(_ data: Data) {
    lock.withLock {
      detectAuthenticationFailure(data)
      pending.append(data)
      flushCompletePrefix()
    }
  }

  func finish() {
    lock.withLock {
      appendRedacted(pending)
      pending.removeAll(keepingCapacity: false)
    }
  }

  func snapshot() -> (text: String, truncated: Bool) {
    lock.withLock {
      let visible = output + redact(pending)
      return (String(decoding: visible, as: UTF8.self), truncated)
    }
  }

  func authenticationFailureObserved() -> Bool {
    lock.withLock { authenticationFailure }
  }

  private func flushCompletePrefix() {
    while pending.count > retainedTailBytes {
      if let pattern = patterns.first(where: { pending.starts(with: $0.0) }) {
        appendBounded(pattern.1)
        pending.removeFirst(pattern.0.count)
        continue
      }
      appendBounded(pending.prefix(1))
      pending.removeFirst()
    }
  }

  private func appendRedacted<S: DataProtocol>(_ source: S) {
    let redacted = redact(Data(source))
    appendBounded(redacted)
  }

  private func appendBounded<S: DataProtocol>(_ source: S) {
    guard output.count < limit else {
      truncated = true
      return
    }
    let data = Data(source)
    let remaining = limit - output.count
    output.append(data.prefix(remaining))
    truncated = truncated || data.count > remaining
  }

  private func redact(_ source: Data) -> Data {
    patterns.reduce(source) { partial, pattern in
      partial.replacingOccurrences(of: pattern.0, with: pattern.1)
    }
  }

  private func detectAuthenticationFailure(_ data: Data) {
    guard !authenticationFailure else { return }
    var normalized = authenticationTail
    normalized.reserveCapacity(authenticationTail.count + data.count)
    for byte in data where !Self.isASCIIWhitespace(byte) {
      normalized.append((UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte)
    }
    let normalizedData = Data(normalized)
    authenticationFailure = authenticationMarkers.contains {
      normalizedData.range(of: Data($0)) != nil
    }
    let retainedCount = max(0, (authenticationMarkers.map(\.count).max() ?? 1) - 1)
    authenticationTail = Array(normalized.suffix(retainedCount))
  }

  private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
  }
}

extension Data {
  fileprivate func replacingOccurrences(of pattern: Data, with replacement: Data) -> Data {
    guard !pattern.isEmpty else { return self }
    var result = Data()
    var searchStart = startIndex
    while let range = range(of: pattern, in: searchStart..<endIndex) {
      result.append(self[searchStart..<range.lowerBound])
      result.append(replacement)
      searchStart = range.upperBound
    }
    result.append(self[searchStart..<endIndex])
    return result
  }
}
