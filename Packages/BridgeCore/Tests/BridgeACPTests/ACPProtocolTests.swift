import Foundation
import XCTest

@testable import BridgeACP

final class ACPProtocolTests: XCTestCase {
  func testJSONValueAndWireMessageRoundTrip() throws {
    let message = ACPWireMessage(
      id: .string("request-1"),
      method: "session/new",
      params: .object([
        "cwd": .string("/tmp/project"),
        "mcpServers": .array([]),
      ])
    )

    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(ACPWireMessage.self, from: data)

    XCTAssertEqual(decoded, message)
    XCTAssertEqual(decoded.id, .string("request-1"))
    XCTAssertEqual(decoded.params?["cwd"], .string("/tmp/project"))
  }

  func testDispatcherClassifiesServerRequestsResponsesAndNotifications() throws {
    let request = try ACPMessageDispatcher.dispatch(
      ACPWireMessage(
        id: .integer(1),
        method: "session/request_permission",
        params: .object([:])
      )
    )
    XCTAssertEqual(
      request,
      .serverRequest(
        id: .integer(1),
        method: "session/request_permission",
        params: .object([:])
      )
    )

    let response = try ACPMessageDispatcher.dispatch(
      ACPWireMessage(id: .integer(2), result: .object(["ok": .bool(true)]))
    )
    XCTAssertEqual(
      response,
      .response(id: .integer(2), result: .object(["ok": .bool(true)]), error: nil)
    )

    let notification = try ACPMessageDispatcher.dispatch(
      ACPWireMessage(method: "session/update", params: .object([:]))
    )
    XCTAssertEqual(
      notification,
      .notification(method: "session/update", params: .object([:]))
    )
  }

  func testDispatcherRejectsAmbiguousOrInvalidMessages() {
    let invalidMessages = [
      ACPWireMessage(
        id: .integer(1),
        result: .object([:]),
        error: ACPWireError(code: -1, message: "both")
      ),
      ACPWireMessage(id: .integer(1)),
      ACPWireMessage(method: ""),
    ]

    for message in invalidMessages {
      XCTAssertThrowsError(try ACPMessageDispatcher.dispatch(message)) { error in
        XCTAssertEqual(error as? ACPError, .invalidMessage)
      }
    }
  }

  func testLineDecoderHandlesFragmentsCRLFAndBoundedFrames() throws {
    var decoder = ACPLineDecoder(maximumFrameBytes: 32)
    XCTAssertTrue(try decoder.append(Data("{\"a\":".utf8)).isEmpty)
    let frames = try decoder.append(Data("1}\r\n{\"b\":2}\n".utf8))

    XCTAssertEqual(
      frames.map { String(decoding: $0, as: UTF8.self) },
      ["{\"a\":1}", "{\"b\":2}"]
    )
  }

  func testLineDecoderRejectsOversizedPartialFrame() {
    var decoder = ACPLineDecoder(maximumFrameBytes: 4)

    XCTAssertThrowsError(try decoder.append(Data("12345".utf8))) { error in
      XCTAssertEqual(error as? ACPError, .oversizedFrame)
    }
  }
}
