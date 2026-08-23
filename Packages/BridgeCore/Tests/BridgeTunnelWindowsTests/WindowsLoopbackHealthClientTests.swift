#if canImport(WinSDK)
  import Foundation
  import WinSDK
  import XCTest

  @testable import BridgeTunnel

  final class WindowsLoopbackHealthClientTests: XCTestCase {
    func testHealthURLAcceptsOnlyStrictIPv4Loopback() throws {
      for (value, expectedPort) in [
        ("http://127.0.0.1:1", 1),
        ("http://127.0.0.1:65535/", 65_535),
        ("  http://127.0.0.1:43210\n", 43_210),
      ] {
        XCTAssertEqual(
          try LoopbackHealthClient.parseHealthURL(Data(value.utf8)),
          expectedPort
        )
      }

      for value in [
        "",
        "http://localhost:43210",
        "http://127.0.0.2:43210",
        "https://127.0.0.1:43210",
        "http://[::1]:43210",
        "http://127.0.0.1:43210/path",
        "http://127.0.0.1:43210?query=1",
        "http://user@127.0.0.1:43210",
        "http://127.0.0.1:0",
        "http://127.0.0.1:65536",
        "http://127.0.0.1:43210\u{0000}",
      ] {
        XCTAssertThrowsError(try LoopbackHealthClient.parseHealthURL(Data(value.utf8))) {
          XCTAssertEqual($0 as? TunnelHealthError, .invalidURLFile, value)
        }
      }
    }

    func testHTTPResponseRequiresExactFraming() throws {
      let response = try HTTPResponse(
        data: Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nready".utf8)
      )
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.body, Data("ready".utf8))

      let chunked = try HTTPResponse(
        data: Data(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nready\r\n0\r\n\r\n".utf8
        )
      )
      XCTAssertEqual(chunked.body, Data("ready".utf8))

      for value in [
        "HTTP/1.1 200 OK\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nready",
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nready!",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nready\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nready",
      ] {
        XCTAssertThrowsError(try HTTPResponse(data: Data(value.utf8))) {
          XCTAssertEqual($0 as? TunnelHealthError, .invalidResponse, value)
        }
      }
    }

    func testPollTimestampRejectsMalformedAndNonFiniteSamples() {
      let valid = Data(
        "commands_poll_last_successful_timestamp_seconds{scope=\"control\"} 0 9999999999999\n".utf8
      )
      XCTAssertEqual(LoopbackHealthClient.pollTimestamp(in: valid), 0)

      for body in [
        Data("commands_poll_last_successful_timestamp_seconds 1 2 3\n".utf8),
        Data("commands_poll_last_successful_timestamp_seconds NaN 2\n".utf8),
        Data("commands_poll_last_successful_timestamp_seconds 1 infinity\n".utf8),
      ] {
        XCTAssertNil(LoopbackHealthClient.pollTimestamp(in: body))
      }
    }

    func testPIDTableParserMatchesListenerPortAndOwner() throws {
      let table = Self.table(
        rows: [
          .init(state: 2, port: 43_210, processID: 1234),
          .init(state: 5, port: 43_210, processID: 5678),
          .init(state: 2, port: 43_211, processID: 5678),
        ]
      )
      let records = try WindowsTCPListenerTable.parse(table)
      XCTAssertEqual(
        records,
        [
          .init(port: 43_210, processID: 1234, state: 2),
          .init(port: 43_210, processID: 5678, state: 5),
          .init(port: 43_211, processID: 5678, state: 2),
        ]
      )
      XCTAssertTrue(
        try WindowsTCPListenerTable.ownsListeningPort(
          in: table,
          port: 43_210,
          processID: 1234
        )
      )
      XCTAssertFalse(
        try WindowsTCPListenerTable.ownsListeningPort(
          in: table,
          port: 43_210,
          processID: 5678
        )
      )
      XCTAssertFalse(
        try WindowsTCPListenerTable.ownsListeningPort(
          in: table,
          port: 43_212,
          processID: 1234
        )
      )
    }

    func testPIDTableParserRejectsTruncatedOrInvalidRows() {
      XCTAssertThrowsError(
        try WindowsTCPListenerTable.parse(Data([1, 0, 0, 0]))
      ) { XCTAssertEqual($0 as? WindowsTCPTableParseError, .malformed) }

      var invalidPort = Self.table(rows: [.init(state: 2, port: 43_210, processID: 1234)])
      invalidPort[14] = 1
      XCTAssertThrowsError(try WindowsTCPListenerTable.parse(invalidPort)) {
        XCTAssertEqual($0 as? WindowsTCPTableParseError, .malformed)
      }
    }

    private struct Row {
      let state: UInt32
      let port: UInt16
      let processID: UInt32
    }

    private static func table(rows: [Row]) -> Data {
      var data = Data()
      append(UInt32(rows.count), to: &data)
      for row in rows {
        append(row.state, to: &data)
        append(0, to: &data)
        append(UInt32(row.port.bigEndian), to: &data)
        append(0, to: &data)
        append(0, to: &data)
        append(row.processID, to: &data)
      }
      return data
    }

    private static func append(_ value: UInt32, to data: inout Data) {
      data.append(UInt8(truncatingIfNeeded: value))
      data.append(UInt8(truncatingIfNeeded: value >> 8))
      data.append(UInt8(truncatingIfNeeded: value >> 16))
      data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
  }
#endif
