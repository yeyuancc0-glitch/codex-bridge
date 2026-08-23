#if canImport(WinSDK)
  import BridgePlatformWindows
  import Foundation
  import WinSDK
  import XCTest

  final class WindowsServicePathsTests: XCTestCase {
    func testPrepareCreatesOwnerOnlyLayoutIdempotently() throws {
      try withTempRoot { root in
        let first = try WindowsServicePaths.prepare(at: root)
        XCTAssertEqual(first.databaseURL.lastPathComponent, "service.sqlite")
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: first.supervisorScratchURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.tunnelRuntimeURL.path))
        XCTAssertFalse(try WindowsServicePaths.prepare(at: root).databaseURL.path.isEmpty)
      }
    }

    func testPrepareRejectsRelativeOrUNCRoots() {
      XCTAssertThrowsError(
        try WindowsServicePaths.prepare(at: URL(fileURLWithPath: "relative/path"))
      )
      XCTAssertThrowsError(
        try WindowsServicePaths.prepare(
          at: URL(fileURLWithPath: "\\\\server\\share\\project", isDirectory: true)
        )
      )
    }

    func testPreexistingWorldReadableDirectoryIsRejected() throws {
      try withTempRoot { root in
        let nested = root.appending(path: "shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        // Everyone-full protected DACL must fail the trust audit.
        try Self.applySDDL("D:P(A;;GA;;;WD)", to: nested.path)
        XCTAssertThrowsError(try WindowsServicePaths.prepareOwnerOnlyDirectory(nested.path)) {
          error in
          XCTAssertEqual(error as? WindowsServicePaths.PathsError, .insecureDirectory)
        }
      }
    }

    func testReparsePointRootIsRejectedWhenSymlinksAreAvailable() throws {
      try withTempRoot { root in
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appending(path: "link", directoryHint: .isDirectory)
        guard Self.createSymlink(link: link.path, target: target.path) else {
          throw XCTSkip("Symbolic links require Developer Mode or privilege")
        }
        XCTAssertThrowsError(try WindowsServicePaths.prepareOwnerOnlyDirectory(link.path)) {
          error in
          XCTAssertEqual(error as? WindowsServicePaths.PathsError, .insecureDirectory)
        }
      }
    }

    private static func applySDDL(_ sddl: String, to path: String) throws {
      var descriptor: UnsafeMutableRawPointer?
      let wide = WideBuffer(sddl)
      guard ConvertStringSecurityDescriptorToSecurityDescriptorW(wide.pointer, 1, &descriptor, nil),
        let descriptor
      else {
        throw XCTSkip("SDDL conversion failed: \(GetLastError())")
      }
      defer { LocalFree(descriptor) }
      var present = WindowsBool(0)
      var defaulted = WindowsBool(0)
      var dacl: PACL?
      guard GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted), let dacl
      else {
        throw XCTSkip("GetSecurityDescriptorDacl failed: \(GetLastError())")
      }
      let pathWide = WideBuffer(path)
      guard
        SetNamedSecurityInfoW(
          pathWide.pointer,
          SE_OBJECT_TYPE(rawValue: 1),
          // DACL_SECURITY_INFORMATION.
          DWORD(0x0000_0004),
          nil,
          nil,
          dacl,
          nil
        ) == ERROR_SUCCESS
      else {
        throw XCTSkip("SetNamedSecurityInfoW failed: \(GetLastError())")
      }
    }

    private static func createSymlink(link: String, target: String) -> Bool {
      // SYMBOLIC_LINK_FLAG_DIRECTORY (0x1) | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE (0x2).
      let flags = DWORD(0x3)
      let linkWide = WideBuffer(link)
      let targetWide = WideBuffer(target)
      return CreateSymbolicLinkW(linkWide.pointer, targetWide.pointer, flags) != 0
    }

    private func withTempRoot(_ body: (URL) throws -> Void) rethrows {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-bridge-paths-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try body(root)
    }
  }
#endif
