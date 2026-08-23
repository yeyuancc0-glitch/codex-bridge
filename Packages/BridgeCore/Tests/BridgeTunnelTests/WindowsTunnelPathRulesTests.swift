import XCTest

@testable import BridgeTunnel

final class WindowsTunnelPathRulesTests: XCTestCase {
  func testNormalizesLocalWindowsPathWithoutChangingRoot() {
    XCTAssertEqual(
      WindowsTunnelPathRules.normalize("C:/CodexBridge/TunnelRuntime/"),
      "C:\\CodexBridge\\TunnelRuntime"
    )
    XCTAssertEqual(WindowsTunnelPathRules.normalize("C:\\"), "C:\\")
  }

  func testAcceptsOnlyDriveAbsolutePaths() {
    XCTAssertTrue(WindowsTunnelPathRules.isLocalAbsolutePath("C:\\CodexBridge"))
    XCTAssertTrue(WindowsTunnelPathRules.isLocalAbsolutePath("z:\\runtime"))
    XCTAssertFalse(WindowsTunnelPathRules.isLocalAbsolutePath("relative\\runtime"))
    XCTAssertFalse(WindowsTunnelPathRules.isLocalAbsolutePath("\\\\server\\share\\runtime"))
    XCTAssertFalse(WindowsTunnelPathRules.isLocalAbsolutePath("C:relative"))
  }

  func testRejectsEscapingAndReservedEntryNames() {
    for name in [
      ".", "..", "name.", "name ", "CON", "nul.txt", "COM1.log", "CLOCK$", "bad:name",
    ] {
      XCTAssertFalse(WindowsTunnelPathRules.isSafeEntryName(name), name)
    }
    XCTAssertTrue(WindowsTunnelPathRules.isSafeEntryName("codex-home"))
    XCTAssertTrue(WindowsTunnelPathRules.isSafeEntryName("health.url"))
    XCTAssertTrue(WindowsTunnelPathRules.isSafeEntryName("console.txt"))
  }

  func testSHA256ContractRequiresLowercaseHexDigest() {
    XCTAssertTrue(WindowsTunnelPathRules.isValidSHA256(String(repeating: "a", count: 64)))
    XCTAssertFalse(WindowsTunnelPathRules.isValidSHA256(String(repeating: "A", count: 64)))
    XCTAssertFalse(WindowsTunnelPathRules.isValidSHA256(String(repeating: "a", count: 63)))
    XCTAssertFalse(
      WindowsTunnelPathRules.isValidSHA256(
        String(repeating: "a", count: 63) + "g"
      )
    )
  }
}
