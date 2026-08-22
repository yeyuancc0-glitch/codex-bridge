import BridgePlatform
import BridgePlatformMacOS
import XCTest

final class MacOSPlatformEnvironmentTests: XCTestCase {
  func testProcessArchitectureIsNative() {
    let environment = MacOSPlatformEnvironment()
    XCTAssertNotEqual(environment.processArchitecture, .unknown)
  }

  func testNativeArchitectureIsKnown() {
    let environment = MacOSPlatformEnvironment()
    XCTAssertNotEqual(environment.nativeOSArchitecture, .unknown)
    XCTAssertTrue(
      [PlatformArchitecture.amd64, .arm64].contains(environment.nativeOSArchitecture)
    )
  }
}
