#if os(Windows)
  import XCTest

  @testable import BridgeCodexService

  final class ExecutionValidationWindowsTests: XCTestCase {
    func testRelativePathAcceptsDriveAndUNCPathsInsideProjectRoots() throws {
      XCTAssertEqual(
        try ExecutionValidation.relativePath(
          #"C:\workspace\project\Sources\App.swift"#,
          root: #"C:\workspace\project"#
        ),
        #"Sources\App.swift"#
      )
      XCTAssertEqual(
        try ExecutionValidation.relativePath(
          #"\\server\share\project\Sources\App.swift"#,
          root: #"\\server\share\project"#
        ),
        #"Sources\App.swift"#
      )
    }

    func testRelativePathRejectsEscapesAndUnsafeRelativeSyntax() {
      for (value, root) in [
        (#"C:\workspace\private\App.swift"#, #"C:\workspace\project"#),
        (#"C:\workspace\project\..\private\App.swift"#, #"C:\workspace\project"#),
        (#"\\server\other\project\App.swift"#, #"\\server\share\project"#),
        (#"Sources\..\App.swift"#, #"C:\workspace\project"#),
      ] {
        XCTAssertThrowsError(try ExecutionValidation.relativePath(value, root: root), value)
      }
    }

    func testRelativePathsTreatWindowsPathsCaseInsensitively() {
      XCTAssertThrowsError(
        try ExecutionValidation.relativePaths(
          [#"Sources\App.swift"#, #"sources\app.swift"#],
          field: "changedFiles"
        )
      )
    }
  }
#endif
