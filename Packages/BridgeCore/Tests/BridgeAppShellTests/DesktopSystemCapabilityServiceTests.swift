import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopSystemCapabilityServiceTests: XCTestCase {
  func testAutomaticExecutableValidationRejectsNonOpenAIBinary() {
    XCTAssertNil(
      DesktopSystemCapabilityService.validatedExecutable(
        URL(fileURLWithPath: "/bin/echo")
      )
    )
  }

  func testAutomaticExecutableValidationAcceptsInstalledOfficialCodexWhenPresent() throws {
    let path = "/Applications/ChatGPT.app/Contents/Resources/codex"
    guard FileManager.default.fileExists(atPath: path) else {
      throw XCTSkip("Official ChatGPT Codex binary is not installed")
    }
    XCTAssertEqual(
      DesktopSystemCapabilityService.validatedExecutable(URL(fileURLWithPath: path))?.path,
      path
    )
  }
}
