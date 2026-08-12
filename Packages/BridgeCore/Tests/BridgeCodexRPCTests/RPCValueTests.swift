import Foundation
import XCTest

@testable import BridgeCodexRPC

final class RPCValueTests: XCTestCase {
  func testRequestIDRoundTripsInt64AndString() throws {
    let values: [RequestID] = [
      .integer(9_007_199_254_740_991),
      .string("approval-request-7"),
    ]

    for value in values {
      let data = try JSONEncoder().encode(value)
      XCTAssertEqual(try JSONDecoder().decode(RequestID.self, from: data), value)
    }
  }

  func testUnknownNotificationPreservesMethodFieldsAndMetadata() throws {
    let value: JSONValue = .object([
      "method": .string("future/event"),
      "params": .object(["futureField": .integer(7)]),
      "emittedAtMs": .integer(42),
      "anotherField": .string("kept"),
    ])

    guard case .notification(let notification) = try RPCEnvelope.decode(value) else {
      return XCTFail("Expected a notification")
    }
    XCTAssertEqual(notification.method, "future/event")
    XCTAssertEqual(
      notification.params?.objectValue?["futureField"],
      .integer(7)
    )
    XCTAssertEqual(notification.metadata["emittedAtMs"], .integer(42))
    XCTAssertEqual(notification.metadata["anotherField"], .string("kept"))
  }

  func testCompleteOversizedLineIsRejectedBeforeDecode() throws {
    var parser = JSONLineParser(maximumLineBytes: 16)
    let oversized = Data((#"{"value":"0123456789"}"# + "\n").utf8)

    XCTAssertThrowsError(try parser.ingest(oversized)) { error in
      XCTAssertEqual(
        error as? CodexRPCError,
        .protocolLineTooLarge(maximumBytes: 16)
      )
    }
  }
}
