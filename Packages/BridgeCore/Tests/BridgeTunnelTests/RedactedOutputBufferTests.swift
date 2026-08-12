import Foundation
import XCTest

@testable import BridgeTunnel

final class RedactedOutputBufferTests: XCTestCase {
  func testRedactsSensitiveValueAcrossEverySplit() {
    let secret = "runtime-secret-value"
    let payload = Data("before:\(secret):after".utf8)
    for split in 0...payload.count {
      let buffer = RedactedOutputBuffer(limit: 1_024, sensitiveValues: [secret])
      buffer.append(payload.prefix(split))
      XCTAssertFalse(buffer.snapshot().text.contains(secret))
      buffer.append(payload.dropFirst(split))
      XCTAssertFalse(buffer.snapshot().text.contains(secret))
      buffer.finish()
      XCTAssertFalse(buffer.snapshot().text.contains(secret))
      XCTAssertTrue(buffer.snapshot().text.contains("<redacted>"))
    }
  }

  func testOutputLimitAppliesAfterRedaction() {
    let buffer = RedactedOutputBuffer(limit: 12, sensitiveValues: ["secret"])
    buffer.append(Data("secret-and-more-output".utf8))
    buffer.finish()
    let snapshot = buffer.snapshot()
    XCTAssertLessThanOrEqual(snapshot.text.utf8.count, 12)
    XCTAssertTrue(snapshot.truncated)
    XCTAssertFalse(snapshot.text.contains("secret"))
  }

  func testAuthenticationFailureRemainsStickyAfterOutputTruncationAndAcrossSplits() {
    let buffer = RedactedOutputBuffer(limit: 8, sensitiveValues: [])
    buffer.append(Data(repeating: UInt8(ascii: "x"), count: 64))
    buffer.append(Data("{\"status_code\":".utf8))
    buffer.append(Data(" 401}\n".utf8))

    XCTAssertTrue(buffer.snapshot().truncated)
    XCTAssertTrue(buffer.authenticationFailureObserved())
  }
}
