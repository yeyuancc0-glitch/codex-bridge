#if os(Windows)
  import BridgeIPC
  import XCTest

  @testable import BridgeServiceHost

  final class WindowsServiceInstanceLockTests: XCTestCase {
    func testSecondLockForTheSameExecutableDirectoryFails() throws {
      let first = try WindowsServiceInstanceLock()
      withExtendedLifetime(first) {
        XCTAssertThrowsError(try WindowsServiceInstanceLock())
      }
    }

    func testPipeAndMutexNamesShareTheDirectoryIdentifier() {
      let directory = #"C:\Codex Bridge\portable"#
      let pipeName = WindowsPipeIdentity.pipeName(forExecutableDirectory: directory)
      let mutexName = WindowsPipeIdentity.mutexName(forExecutableDirectory: directory)
      let suffix = String(mutexName.split(separator: ".").last ?? "")

      XCTAssertTrue(pipeName.hasSuffix(".\(suffix)"))
      XCTAssertNotEqual(
        pipeName,
        WindowsPipeIdentity.pipeName(forExecutableDirectory: #"C:\Codex Bridge\other"#)
      )
    }
  }
#endif
