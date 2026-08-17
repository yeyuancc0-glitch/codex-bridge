import Darwin
import Foundation

struct TunnelHealthSnapshot: Equatable, Sendable {
  let isReady: Bool
  let pollTimestamp: TimeInterval?
}

struct LoopbackHealthClient: Sendable {
  static let urlFileName = "health.url"

  private let maximumResponseBytes = 64 * 1024

  func snapshot(
    urlFileDirectory: TunnelDirectoryHandle,
    expectedPeerPID: pid_t
  ) throws -> TunnelHealthSnapshot {
    let baseURL = try healthBaseURL(in: urlFileDirectory)
    guard Self.process(expectedPeerPID, ownsListeningPort: baseURL.port!) else {
      throw TunnelHealthError.unexpectedPeer
    }
    let ready = try request(path: "/readyz", baseURL: baseURL)
    let metrics = try request(path: "/metrics", baseURL: baseURL)
    return TunnelHealthSnapshot(
      isReady: ready.status == 200 && ready.body == Data("ready".utf8),
      pollTimestamp: metrics.status == 200 ? Self.pollTimestamp(in: metrics.body) : nil
    )
  }

  private func healthBaseURL(in directory: TunnelDirectoryHandle) throws -> URL {
    let data = try directory.readRegularFile(
      name: Self.urlFileName,
      maximumBytes: 2_048
    )
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw TunnelHealthError.invalidURLFile
    }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty,
      value.utf8.count <= 2_048,
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      let components = URLComponents(string: value),
      components.scheme == "http",
      components.host == "127.0.0.1",
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
      let port = components.port,
      (1...65_535).contains(port)
    else {
      throw TunnelHealthError.invalidURLFile
    }
    var normalized = URLComponents()
    normalized.scheme = "http"
    normalized.host = "127.0.0.1"
    normalized.port = port
    guard let url = normalized.url else {
      throw TunnelHealthError.invalidURLFile
    }
    return url
  }

  private func request(path: String, baseURL: URL) throws -> HTTPResponse {
    guard let port = baseURL.port else { throw TunnelHealthError.invalidURLFile }
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TunnelHealthError.unavailable }
    defer { Darwin.close(descriptor) }
    try setTimeout(descriptor)
    try connect(descriptor, port: port)
    let request = Data(
      "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8
    )
    try write(request, to: descriptor)
    return try readResponse(from: descriptor)
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

  private func connect(_ descriptor: Int32, port: Int) throws {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
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
    var chunk = [UInt8](repeating: 0, count: 4_096)
    while response.count <= maximumResponseBytes {
      let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
      if count == 0 { break }
      guard count > 0 else { throw TunnelHealthError.unavailable }
      response.append(chunk, count: count)
    }
    guard response.count <= maximumResponseBytes else {
      throw TunnelHealthError.responseTooLarge
    }
    return try HTTPResponse(data: response)
  }

  package static func pollTimestamp(in body: Data) -> TimeInterval? {
    let text = String(decoding: body, as: UTF8.self)
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count == 2 || fields.count == 3 else { continue }
      let metric = fields[0].split(separator: "{").first
      guard metric == "commands_poll_last_successful_timestamp_seconds" else { continue }
      guard let value = Double(fields[1]), value.isFinite else { continue }
      if fields.count == 3 {
        guard let sampleTimestamp = Double(fields[2]), sampleTimestamp.isFinite else {
          continue
        }
      }
      return value
    }
    return nil
  }

  private static func process(_ processID: pid_t, ownsListeningPort port: Int) -> Bool {
    let requiredBytes = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
    guard requiredBytes > 0 else { return false }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [
      proc_fdinfo
    ](repeating: proc_fdinfo(), count: Int(requiredBytes) / stride + 16)
    let returnedBytes = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(
        processID,
        PROC_PIDLISTFDS,
        0,
        buffer.baseAddress,
        Int32(buffer.count)
      )
    }
    guard returnedBytes > 0 else { return false }
    let count = min(Int(returnedBytes) / stride, descriptors.count)
    return descriptors.prefix(count).contains { descriptor in
      guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { return false }
      var socket = socket_fdinfo()
      let bytes = withUnsafeMutablePointer(to: &socket) { pointer in
        proc_pidfdinfo(
          processID,
          descriptor.proc_fd,
          PROC_PIDFDSOCKETINFO,
          pointer,
          Int32(MemoryLayout<socket_fdinfo>.size)
        )
      }
      guard bytes == MemoryLayout<socket_fdinfo>.size,
        socket.psi.soi_family == AF_INET,
        socket.psi.soi_kind == SOCKINFO_TCP,
        socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
      else {
        return false
      }
      let localPort = Int(
        UInt16(
          bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
      )
      return localPort == port
    }
  }
}

package struct HTTPResponse {
  let status: Int
  let body: Data

  init(data: Data) throws {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let split = data.range(of: delimiter) else {
      throw TunnelHealthError.invalidResponse
    }
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
  case invalidURLFile
  case invalidResponse
  case responseTooLarge
  case unexpectedPeer
}
