import BridgeCodexRPC
import Foundation
import XCTest

final class AppServerConfigurationWindowsTests: XCTestCase {
  func testCustomConfigurationPreservesStructuredInvocation() {
    let executable = URL(fileURLWithPath: #"C:\Program Files\Codex\codex.exe"#)
    let configuration = AppServerConfiguration(
      executableURL: executable,
      arguments: ["app-server", "--stdio", "argument with spaces"],
      maximumProtocolLineBytes: 0,
      stderrBufferBytes: -1
    )

    XCTAssertEqual(configuration.executableURL, executable)
    XCTAssertEqual(
      configuration.arguments,
      ["app-server", "--stdio", "argument with spaces"]
    )
    XCTAssertEqual(configuration.maximumProtocolLineBytes, 1)
    XCTAssertEqual(configuration.stderrBufferBytes, 0)
  }
}
