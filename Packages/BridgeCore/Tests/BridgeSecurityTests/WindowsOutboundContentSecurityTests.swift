#if os(Windows)
  import XCTest

  @testable import BridgeSecurity

  final class WindowsOutboundContentSecurityTests: XCTestCase {
    func testRelativePathContractAcceptsWindowsSeparatorsAndRejectsAbsoluteForms() {
      XCTAssertTrue(OutboundContentSecurity.isSafeRelativePath(#"Sources\App.swift"#))
      XCTAssertTrue(OutboundContentSecurity.isSafeRelativePath("Sources/App.swift"))
      XCTAssertTrue(OutboundContentSecurity.isSafeOutboundRelativePath(#"Sources\App.swift"#))

      for value in [
        #"C:\workspace\project\App.swift"#,
        #"\server\share\App.swift"#,
        #"\\server\share\App.swift"#,
        #"Sources\..\App.swift"#,
        #"Sources\.\App.swift"#,
      ] {
        XCTAssertFalse(OutboundContentSecurity.isSafeRelativePath(value), value)
      }
    }

    func testContentSecurityRedactsDriveAndUNCPaths() {
      for value in [
        #"Open C:\Users\Alice\secret.txt"#,
        #"Open \server\share\secret.txt"#,
        #"Open \\server\share\secret.txt"#,
      ] {
        XCTAssertFalse(OutboundContentSecurity.isSafe(value), value)
        XCTAssertFalse(
          OutboundContentSecurity.redacted(value, maximumUTF8Bytes: 4_096).contains(
            "secret.txt"
          ))
      }
    }

    func testCommandOutputRedactionHandlesWindowsLineAndColumnSuffix() {
      let input = #"error: C:\Users\Alice\Project\App.swift:20:7: assertion failed status=failed"#
      let redacted = OutboundContentSecurity.redactedCommandOutput(
        input,
        maximumUTF8Bytes: 4_096
      )

      XCTAssertFalse(redacted.contains(#"C:\Users"#))
      XCTAssertTrue(redacted.contains(":20:7: assertion failed status=failed"))
    }
  }
#endif
