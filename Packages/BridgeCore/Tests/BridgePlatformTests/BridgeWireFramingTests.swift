import BridgePlatform
import XCTest

final class BridgeWireFramingTests: XCTestCase {
  func testFrameRoundTripsAndExtractsCompleteBodies() throws {
    let message = Data("contract".utf8)
    let framed = try BridgeWireFraming.frame(message)
    XCTAssertEqual(framed.count, BridgeWireFraming.headerByteCount + message.count)
    let (frames, consumed) = try BridgeWireFraming.extractFrames(from: framed)
    XCTAssertEqual(frames, [message])
    XCTAssertEqual(consumed, framed.count)
  }

  func testPartialInputIsKeptAndNeverAllocatesBodyEarly() throws {
    let message = Data("streamed".utf8)
    let framed = try BridgeWireFraming.frame(message)
    for cut in 1..<framed.count {
      let partial = try BridgeWireFraming.extractFrames(from: framed.prefix(cut))
      XCTAssertTrue(partial.frames.isEmpty, "cut=\(cut)")
      XCTAssertEqual(partial.consumed, 0, "cut=\(cut)")
    }
  }

  func testOversizedDeclarationsAreRejectedBeforeAllocation() {
    let allOnes = Data([0xFF, 0xFF, 0xFF, 0xFF])
    XCTAssertThrowsError(try BridgeWireFraming.declaredLength(allOnes))
    let overLimit = (UInt32(BridgeWireLimits.maximumMessageBytes) + 1).littleEndianBytes
    XCTAssertThrowsError(try BridgeWireFraming.declaredLength(Data(overLimit)))
    let atLimit = UInt32(BridgeWireLimits.maximumMessageBytes).littleEndianBytes
    XCTAssertNoThrow(try BridgeWireFraming.declaredLength(Data(atLimit)))
  }

  func testOversizedMessagesCannotBeFramed() {
    XCTAssertThrowsError(
      try BridgeWireFraming.frame(Data(count: BridgeWireLimits.maximumMessageBytes + 1))
    )
  }

  func testMultipleFramesInOneBufferDecodeSequentially() throws {
    let first = try BridgeWireFraming.frame(Data("a".utf8))
    let second = try BridgeWireFraming.frame(Data("bb".utf8))
    var combined = first
    combined.append(second)
    let (frames, consumed) = try BridgeWireFraming.extractFrames(from: combined)
    XCTAssertEqual(frames, [Data("a".utf8), Data("bb".utf8)])
    XCTAssertEqual(consumed, combined.count)
  }

  func testTruncatedHeaderIsRejected() {
    XCTAssertThrowsError(try BridgeWireFraming.declaredLength(Data([0x01, 0x02])))
  }
}

extension UInt32 {
  fileprivate var littleEndianBytes: [UInt8] {
    withUnsafeBytes(of: self.littleEndian) { Array($0) }
  }
}
