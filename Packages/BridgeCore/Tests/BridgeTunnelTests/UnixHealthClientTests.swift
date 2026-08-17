import Darwin
import Foundation
import XCTest

@testable import BridgeTunnel

final class LoopbackHealthClientTests: XCTestCase {
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

  func testPollTimestampUsesMetricValueBeforeOptionalPrometheusSampleTimestamp() {
    let body = Data(
      ("# HELP commands_poll_last_successful_timestamp_seconds Poll\n"
        + "commands_poll_last_successful_timestamp_seconds{scope=\"control\"} 0 9999999999999\n")
        .utf8
    )

    XCTAssertEqual(LoopbackHealthClient.pollTimestamp(in: body), 0)
  }

  func testPollTimestampRejectsMalformedOrNonFiniteSamples() {
    let bodies = [
      Data("commands_poll_last_successful_timestamp_seconds 1 2 3\n".utf8),
      Data("commands_poll_last_successful_timestamp_seconds NaN 2\n".utf8),
      Data("commands_poll_last_successful_timestamp_seconds 1 infinity\n".utf8),
    ]

    for body in bodies {
      XCTAssertNil(LoopbackHealthClient.pollTimestamp(in: body))
    }
  }

  func testHealthURLRejectsUnexpectedListeningProcess() throws {
    let fixture = try HealthURLFixture()
    defer { fixture.close() }

    XCTAssertThrowsError(
      try LoopbackHealthClient().snapshot(
        urlFileDirectory: fixture.directory,
        expectedPeerPID: getpid() + 1
      )
    ) {
      XCTAssertEqual($0 as? TunnelHealthError, .unexpectedPeer)
    }
  }

  func testHealthURLFileMustBePrivateAndLoopbackOnly() throws {
    let fixture = try HealthURLFixture()
    defer { fixture.close() }
    let file = fixture.root.appendingPathComponent(LoopbackHealthClient.urlFileName)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: file.path
    )

    XCTAssertThrowsError(
      try LoopbackHealthClient().snapshot(
        urlFileDirectory: fixture.directory,
        expectedPeerPID: getpid()
      )
    ) {
      XCTAssertEqual($0 as? TunnelHealthError, .invalidURLFile)
    }
  }
}

private final class HealthURLFixture {
  let root: URL
  let directory: TunnelDirectoryHandle
  private let descriptor: Int32

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "health-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    directory = try TunnelDirectoryHandle(existingRoot: root)

    descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TunnelHealthError.unavailable }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard status == 0, listen(descriptor, 1) == 0 else {
      Darwin.close(descriptor)
      throw TunnelHealthError.unavailable
    }

    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameStatus = withUnsafeMutablePointer(to: &bound) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard nameStatus == 0 else {
      Darwin.close(descriptor)
      throw TunnelHealthError.unavailable
    }
    let port = UInt16(bigEndian: bound.sin_port)
    let file = root.appendingPathComponent(LoopbackHealthClient.urlFileName)
    try Data("http://127.0.0.1:\(port)".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  func close() {
    Darwin.close(descriptor)
    try? FileManager.default.removeItem(at: root)
  }
}
