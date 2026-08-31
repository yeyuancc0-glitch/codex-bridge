#if os(Windows)
  import XCTest

  @testable import BridgeDirectCommand

  final class DirectCommandWindowsContractTests: XCTestCase {
    func testBuiltInSafeCommandsAreNotAdvertisedWithoutNetworkIsolation() {
      XCTAssertTrue(DirectCommandPolicy().effectiveSafeCommandRules.isEmpty)
    }

    func testDenyNetworkFailsClosedBeforeProcessLaunch() {
      let output = DirectCommandOutputCollector(maximumBytes: 1_024)
      XCTAssertThrowsError(
        try DirectProcessLifetime(
          argv: [#"C:\Windows\System32\cmd.exe"#],
          workingDirectory: nil,
          environment: nil,
          usePTY: false,
          output: output,
          denyNetwork: true
        )
      ) { error in
        XCTAssertEqual(error as? DirectProcessError, .sandboxUnavailable)
      }
    }
  }
#endif
