#if canImport(WinSDK)
  import Foundation
  import XCTest

  @testable import BridgeServiceHost

  final class WindowsServiceProcessOptionsTests: XCTestCase {
    func testServiceBundleLocatorReturnsCurrentExecutableDirectory() throws {
      let directory = try XCTUnwrap(ServiceBundleLocator.currentAppBundleURL())
      XCTAssertTrue(directory.isFileURL)
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

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

    func testServiceInstanceLeaseRejectsSecondHost() throws {
      let first = try WindowsServiceInstanceLease()
      XCTAssertThrowsError(try WindowsServiceInstanceLease()) { error in
        XCTAssertEqual(error as? WindowsServiceInstanceLeaseError, .alreadyRunning)
      }
      withExtendedLifetime(first) {}
    }
  }
#endif
