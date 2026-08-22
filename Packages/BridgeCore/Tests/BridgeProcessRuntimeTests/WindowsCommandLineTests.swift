import BridgeProcessRuntime
import XCTest

final class WindowsCommandLineTests: XCTestCase {
  func testEncodesNativeArgumentsWithoutInvokingShellRules() throws {
    XCTAssertEqual(
      try WindowsCommandLine.encode([
        #"C:\Program Files\Codex\codex.exe"#,
        "app-server",
        "--stdio",
        "&|<>^()%!",
      ]),
      #""C:\Program Files\Codex\codex.exe" app-server --stdio &|<>^()%!"#
    )
  }

  func testPreservesEmptyQuotedAndTrailingBackslashArguments() throws {
    XCTAssertEqual(
      try WindowsCommandLine.encode([
        "tool.exe",
        "",
        #"a b\"#,
        #"say "hello""#,
      ]),
      #"tool.exe "" "a b\\" "say \"hello\"""#
    )
  }

  func testRejectsInvalidInvocations() {
    XCTAssertThrowsError(try WindowsCommandLine.encode([])) { error in
      XCTAssertEqual(error as? WindowsCommandLineError, .emptyInvocation)
    }
    XCTAssertThrowsError(try WindowsCommandLine.encode(["tool.exe", "bad\0value"])) { error in
      XCTAssertEqual(error as? WindowsCommandLineError, .invalidNullCharacter)
    }
  }
}
