import Foundation

/// Wire framing shared by every transport that carries the bridge IPC JSON
/// contract over a stream or message channel: a 4-byte little-endian byte
/// count followed by exactly that many bytes of a single codec message.
///
/// The C# client mirrors this layout; treat it as part of the frozen wire
/// contract alongside `schemaVersion`.
public enum BridgeWireFraming {
  public static let headerByteCount = 4

  public enum FramingError: Error, Equatable, Sendable {
    case frameTooLarge(UInt32)
    case truncatedHeader
    case truncatedBody(expected: Int, received: Int)
    case trailingBytes(Int)
  }

  /// Wraps one encoded message into a single self-delimiting frame.
  public static func frame(_ message: Data) throws -> Data {
    guard message.count <= BridgeWireLimits.maximumMessageBytes else {
      throw FramingError.frameTooLarge(UInt32(BridgeWireLimits.maximumMessageBytes))
    }
    var framed = Data(capacity: headerByteCount + message.count)
    var length = UInt32(message.count).littleEndian
    withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
    framed.append(message)
    return framed
  }

  /// Extracts the declared body size from a complete little-endian header.
  /// Rejects oversized declarations before any body allocation happens.
  public static func declaredLength(_ header: Data) throws -> Int {
    guard header.count >= headerByteCount else { throw FramingError.truncatedHeader }
    var length: UInt32 = 0
    for (offset, byte) in header.prefix(headerByteCount).enumerated() {
      length |= UInt32(byte) << (8 * UInt32(offset))
    }
    guard Int(length) <= BridgeWireLimits.maximumMessageBytes else {
      throw FramingError.frameTooLarge(length)
    }
    return Int(length)
  }

  /// Feeds accumulated bytes into the decoder and returns every complete
  /// frame body plus the number of consumed bytes. Partial input is kept.
  public static func extractFrames(
    from buffer: Data
  ) throws -> (frames: [Data], consumed: Int) {
    var frames: [Data] = []
    var offset = 0
    while buffer.count - offset >= headerByteCount {
      let header = buffer.subdata(in: offset..<offset + headerByteCount)
      let length = try declaredLength(header)
      let end = offset + headerByteCount + length
      guard buffer.count >= end else { break }
      frames.append(buffer.subdata(in: offset + headerByteCount..<end))
      offset = end
    }
    return (frames, offset)
  }
}
