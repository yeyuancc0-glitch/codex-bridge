import Foundation

public enum BoundedLineDecoderError: Error, Equatable, Sendable {
  case oversizedFrame
}

/// Incrementally splits LF-delimited process output while enforcing a hard
/// per-frame limit. CRLF is accepted, empty lines are ignored, and a final
/// unterminated frame is returned by `finish()`.
public struct BoundedLineDecoder: Sendable {
  public let maximumFrameBytes: Int
  private var buffer = Data()

  public init(maximumFrameBytes: Int = 1_048_576) {
    self.maximumFrameBytes = max(1, maximumFrameBytes)
  }

  public mutating func append(_ data: Data) throws -> [Data] {
    guard !data.isEmpty else { return [] }
    buffer.append(data)
    var frames: [Data] = []

    while let newline = buffer.firstIndex(of: 0x0A) {
      var frame = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if frame.last == 0x0D { frame.removeLast() }
      if frame.isEmpty { continue }
      guard frame.count <= maximumFrameBytes else {
        throw BoundedLineDecoderError.oversizedFrame
      }
      frames.append(frame)
    }

    guard buffer.count <= maximumFrameBytes else {
      throw BoundedLineDecoderError.oversizedFrame
    }
    return frames
  }

  public mutating func finish() throws -> [Data] {
    guard !buffer.isEmpty else { return [] }
    var frame = buffer
    buffer.removeAll(keepingCapacity: false)
    if frame.last == 0x0D { frame.removeLast() }
    guard frame.count <= maximumFrameBytes else {
      throw BoundedLineDecoderError.oversizedFrame
    }
    return frame.isEmpty ? [] : [frame]
  }
}
