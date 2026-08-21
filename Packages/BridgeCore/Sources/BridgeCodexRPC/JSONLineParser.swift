import Foundation

struct JSONLineParser: Sendable {
  private var buffer = Data()
  private let maximumLineBytes: Int

  init(maximumLineBytes: Int = 8 * 1024 * 1024) {
    self.maximumLineBytes = maximumLineBytes
  }

  mutating func ingest(_ data: Data) throws -> [JSONValue] {
    buffer.append(data)
    var messages: [JSONValue] = []

    while let newline = buffer.firstIndex(of: 0x0A) {
      guard newline <= maximumLineBytes else {
        buffer.removeAll(keepingCapacity: false)
        throw CodexRPCError.protocolLineTooLarge(maximumBytes: maximumLineBytes)
      }
      let line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if let message = try decode(line) {
        messages.append(message)
      }
    }

    guard buffer.count <= maximumLineBytes else {
      buffer.removeAll(keepingCapacity: false)
      throw CodexRPCError.protocolLineTooLarge(maximumBytes: maximumLineBytes)
    }
    return messages
  }

  mutating func finish() throws -> [JSONValue] {
    defer { buffer.removeAll(keepingCapacity: false) }
    guard buffer.count <= maximumLineBytes else {
      throw CodexRPCError.protocolLineTooLarge(maximumBytes: maximumLineBytes)
    }
    guard let message = try decode(buffer) else { return [] }
    return [message]
  }

  private func decode(_ line: Data) throws -> JSONValue? {
    let trimmed = line.trimmingASCIIWhitespace()
    guard !trimmed.isEmpty else { return nil }
    guard String(data: trimmed, encoding: .utf8) != nil else {
      throw CodexRPCError.invalidUTF8
    }

    do {
      return try JSONDecoder().decode(JSONValue.self, from: trimmed)
    } catch {
      let preview = String(decoding: trimmed.prefix(160), as: UTF8.self)
      guard preview.first == "{" else {
        throw CodexRPCError.protocolContamination(preview)
      }
      throw CodexRPCError.malformedMessage(error.localizedDescription)
    }
  }
}

extension Data {
  fileprivate func trimmingASCIIWhitespace() -> Data {
    let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
    guard let first = firstIndex(where: { !whitespace.contains($0) }) else {
      return Data()
    }
    let last = lastIndex(where: { !whitespace.contains($0) }) ?? first
    return Data(self[first...last])
  }
}
