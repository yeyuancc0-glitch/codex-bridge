#if canImport(WinSDK)
  import Foundation
  import XCTest

  @testable import BridgeServiceHost

  final class WindowsServiceProcessOptionsTests: XCTestCase {
    func testParsesForegroundAndLocalDataRoot() throws {
      let options = try WindowsServiceProcessOptions.parse([
        "--foreground", "--data-root", "C:\\Users\\bridge\\Service",
      ])
      XCTAssertTrue(options.foreground)
      XCTAssertTrue(options.dataRootURL.isFileURL)
    }

    func testRejectsMissingUnknownRelativeAndNetworkArguments() {
      XCTAssertThrowsError(try WindowsServiceProcessOptions.parse(["--data-root"]))
      XCTAssertThrowsError(try WindowsServiceProcessOptions.parse(["--unknown"]))
      XCTAssertThrowsError(
        try WindowsServiceProcessOptions.parse(["--data-root", "relative\\Service"])
      )
      XCTAssertThrowsError(
        try WindowsServiceProcessOptions.parse(["--data-root", "\\\\server\\share"])
      )
    }
  }
#endif
