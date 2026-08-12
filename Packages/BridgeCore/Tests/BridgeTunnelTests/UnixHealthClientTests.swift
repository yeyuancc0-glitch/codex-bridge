import Darwin
import Foundation
import XCTest

@testable import BridgeTunnel

final class UnixHealthClientTests: XCTestCase {
  func testStrictContentLengthRejectsEmptyDuplicateAndMissingValues() throws {
    for head in [
      "HTTP/1.1 200 OK\r\nContent-Length:\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
      "HTTP/1.1 200 OK\r\n\r\n",
    ] {
      XCTAssertThrowsError(try HTTPResponse(data: Data(head.utf8))) {
        XCTAssertEqual($0 as? TunnelHealthError, .invalidResponse)
      }
    }
  }

  func testStrictContentLengthAcceptsExactDecimalBody() throws {
    let response = try HTTPResponse(
      data: Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nready".utf8)
    )
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body, Data("ready".utf8))
  }

  func testHealthSocketRejectsUnexpectedPeerPID() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "health-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try TestUnixServer(path: directory.appendingPathComponent("health.sock").path)
    defer { server.close() }
    let accepted = Task.detached { server.acceptOnce() }

    XCTAssertThrowsError(
      try UnixHealthClient().snapshot(
        socketPath: server.path,
        expectedPeerPID: getpid() + 1
      )
    ) {
      XCTAssertEqual($0 as? TunnelHealthError, .unexpectedPeer)
    }
    await accepted.value
  }
}

private final class TestUnixServer: @unchecked Sendable {
  let path: String
  private let descriptor: Int32

  init(path: String) throws {
    self.path = path
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TunnelHealthError.unavailable }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(descriptor)
      throw TunnelHealthError.invalidSocketPath
    }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
        bytes.withUnsafeBytes { memcpy(destination, $0.baseAddress!, bytes.count) }
      }
    }
    let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path)!
    let length = socklen_t(offset + bytes.count)
    address.sun_len = UInt8(length)
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, length)
      }
    }
    guard status == 0, listen(descriptor, 1) == 0 else {
      Darwin.close(descriptor)
      throw TunnelHealthError.unavailable
    }
  }

  func acceptOnce() {
    let client = accept(descriptor, nil, nil)
    guard client >= 0 else { return }
    usleep(200_000)
    Darwin.close(client)
  }

  func close() {
    Darwin.close(descriptor)
    unlink(path)
  }
}
