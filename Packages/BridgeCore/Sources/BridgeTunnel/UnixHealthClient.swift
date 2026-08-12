import Darwin
import Foundation

struct TunnelHealthSnapshot: Equatable, Sendable {
  let isReady: Bool
  let pollTimestamp: TimeInterval?
}

struct UnixHealthClient: Sendable {
  private let maximumResponseBytes = 64 * 1024

  func snapshot(socketPath: String, expectedPeerPID: pid_t) throws -> TunnelHealthSnapshot {
    let ready = try request(
      path: "/readyz",
      socketPath: socketPath,
      expectedPeerPID: expectedPeerPID
    )
    let metrics = try request(
      path: "/metrics",
      socketPath: socketPath,
      expectedPeerPID: expectedPeerPID
    )
    return TunnelHealthSnapshot(
      isReady: ready.status == 200 && ready.body == Data("ready".utf8),
      pollTimestamp: metrics.status == 200 ? Self.pollTimestamp(in: metrics.body) : nil
    )
  }

  private func request(
    path: String,
    socketPath: String,
    expectedPeerPID: pid_t
  ) throws -> HTTPResponse {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TunnelHealthError.unavailable }
    defer { Darwin.close(descriptor) }
    try setTimeout(descriptor)
    try connect(descriptor, path: socketPath)
    try verifyPeer(descriptor, expectedPID: expectedPeerPID)
    let request = Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
    try write(request, to: descriptor)
    return try readResponse(from: descriptor)
  }

  private func verifyPeer(_ descriptor: Int32, expectedPID: pid_t) throws {
    var peerPID: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard
      getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0,
      length == MemoryLayout<pid_t>.size,
      peerPID == expectedPID
    else {
      throw TunnelHealthError.unexpectedPeer
    }
  }

  private func setTimeout(_ descriptor: Int32) throws {
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
      setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0
    else {
      throw TunnelHealthError.unavailable
    }
  }

  private func connect(_ descriptor: Int32, path: String) throws {
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw TunnelHealthError.invalidSocketPath
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
        bytes.withUnsafeBytes { source in
          memcpy(destination, source.baseAddress!, bytes.count)
        }
      }
    }
    let pathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path)!
    let length = socklen_t(pathOffset + bytes.count)
    address.sun_len = UInt8(length)
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, length)
      }
    }
    guard status == 0 else { throw TunnelHealthError.unavailable }
  }

  private func write(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.send(
          descriptor,
          baseAddress.advanced(by: offset),
          bytes.count - offset,
          MSG_NOSIGNAL
        )
        guard count > 0 else { throw TunnelHealthError.unavailable }
        offset += count
      }
    }
  }

  private func readResponse(from descriptor: Int32) throws -> HTTPResponse {
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while response.count <= maximumResponseBytes {
      let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
      if count == 0 { break }
      guard count > 0 else { throw TunnelHealthError.unavailable }
      response.append(chunk, count: count)
    }
    guard response.count <= maximumResponseBytes else { throw TunnelHealthError.responseTooLarge }
    return try HTTPResponse(data: response)
  }

  private static func pollTimestamp(in body: Data) -> TimeInterval? {
    let text = String(decoding: body, as: UTF8.self)
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2 else { continue }
      let metric = fields[0].split(separator: "{").first
      guard metric == "commands_poll_last_successful_timestamp_seconds" else { continue }
      return TimeInterval(fields.last!)
    }
    return nil
  }
}

package struct HTTPResponse {
  let status: Int
  let body: Data

  init(data: Data) throws {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let split = data.range(of: delimiter) else { throw TunnelHealthError.invalidResponse }
    let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
    guard let firstLine = head.split(separator: "\r\n").first else {
      throw TunnelHealthError.invalidResponse
    }
    let parts = firstLine.split(separator: " ")
    guard
      parts.count >= 2,
      parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0",
      let status = Int(parts[1]),
      (100...599).contains(status)
    else {
      throw TunnelHealthError.invalidResponse
    }
    guard !head.lowercased().contains("transfer-encoding:") else {
      throw TunnelHealthError.invalidResponse
    }
    self.status = status
    body = Data(data[split.upperBound...])
    if try Self.contentLength(in: head) != body.count {
      throw TunnelHealthError.invalidResponse
    }
  }

  private static func contentLength(in head: String) throws -> Int {
    let lines = head.components(separatedBy: "\r\n").dropFirst()
    let values = lines.compactMap { line -> String? in
      guard let separator = line.firstIndex(of: ":") else { return nil }
      let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      guard name == "content-length" else { return nil }
      return line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
    }
    guard
      values.count == 1,
      let value = values.first,
      !value.isEmpty,
      value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
      let length = Int(value)
    else {
      throw TunnelHealthError.invalidResponse
    }
    return length
  }
}

enum TunnelHealthError: Error, Equatable, Sendable {
  case unavailable
  case invalidSocketPath
  case invalidResponse
  case responseTooLarge
  case unexpectedPeer
}
