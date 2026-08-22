#if canImport(WinSDK)
  @testable import BridgeProcessRuntime
  import Foundation
  import XCTest

  final class WindowsLocalPathValidatorTests: XCTestCase {
    func testAcceptsLocalDirectoryAndRegularFileWithSpaces() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex bridge path test \(UUID().uuidString)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("fixture.exe")
      try Data([0x4D, 0x5A]).write(to: file)

      XCTAssertTrue(
        WindowsPath.equivalent(
          try WindowsLocalPathValidator.validate(root.path, kind: .directory),
          root.path
        )
      )
      XCTAssertTrue(
        WindowsPath.equivalent(
          try WindowsLocalPathValidator.validate(file.path, kind: .regularFile),
          file.path
        )
      )
    }

    func testRejectsWrongKindNetworkADSAndAmbiguousComponents() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-bridge-path-kind-\(UUID().uuidString)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("fixture.exe")
      try Data([0x4D, 0x5A]).write(to: file)

      XCTAssertThrowsError(
        try WindowsLocalPathValidator.validate(root.path, kind: .regularFile)
      ) { error in
        XCTAssertEqual(error as? WindowsLocalPathError, .wrongKind)
      }
      XCTAssertThrowsError(
        try WindowsLocalPathValidator.validate(file.path, kind: .directory)
      ) { error in
        XCTAssertEqual(error as? WindowsLocalPathError, .wrongKind)
      }
      XCTAssertThrowsError(
        try WindowsLocalPathValidator.validate(#"\\server\share\tool.exe"#, kind: .regularFile)
      ) { error in
        XCTAssertEqual(error as? WindowsLocalPathError, .networkPathDenied)
      }
      XCTAssertThrowsError(
        try WindowsLocalPathValidator.validate(
          root.path + #"\file.exe:payload"#, kind: .regularFile)
      ) { error in
        XCTAssertEqual(error as? WindowsLocalPathError, .invalidPath)
      }
      XCTAssertThrowsError(
        try WindowsLocalPathValidator.validate(root.path + #"\..\tool.exe"#, kind: .regularFile)
      ) { error in
        XCTAssertEqual(error as? WindowsLocalPathError, .invalidPath)
      }
      XCTAssertThrowsError(
        try WindowsLocalPathValidator.validate(root.path + #"\tool.exe. "#, kind: .regularFile)
      ) { error in
        XCTAssertEqual(error as? WindowsLocalPathError, .invalidPath)
      }
    }
  }
#endif
