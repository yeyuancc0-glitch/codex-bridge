import Foundation
import XCTest

@testable import BridgeOpenCodeACP

final class ACPLineDecoderTests: XCTestCase {
  func testReassemblesFragmentedCRLFAndLFFrames() throws {
    var decoder = ACPLineDecoder(maximumFrameBytes: 64)

    XCTAssertTrue(try decoder.append(Data("{\"a\":".utf8)).isEmpty)
    let frames = try decoder.append(Data("1}\r\n{\"b\":2}\n".utf8))

    XCTAssertEqual(frames.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
    XCTAssertTrue(try decoder.finish().isEmpty)
  }

  func testRejectsOversizedPartialFrameBeforeNewline() throws {
    var decoder = ACPLineDecoder(maximumFrameBytes: 4)

    XCTAssertThrowsError(try decoder.append(Data("12345".utf8))) { error in
      XCTAssertEqual(error as? OpenCodeACPError, .oversizedFrame)
    }
  }

  func testFinishReturnsBoundedTrailingFrame() throws {
    var decoder = ACPLineDecoder(maximumFrameBytes: 16)
    _ = try decoder.append(Data("{\"ok\":true}".utf8))

    let frames = try decoder.finish()

    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(String(decoding: frames[0], as: UTF8.self), "{\"ok\":true}")
  }
}
