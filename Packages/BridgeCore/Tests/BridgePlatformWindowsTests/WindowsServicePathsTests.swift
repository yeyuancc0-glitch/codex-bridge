#if canImport(WinSDK)
  @testable import BridgePlatformWindows
  import Foundation
  import WinSDK
  import XCTest

  final class WindowsServicePathsTests: XCTestCase {
    func testPrepareCreatesOwnerOnlyLayoutIdempotently() throws {
      try withTempRoot { root in
        let serviceRoot =
          root
          .appending(path: "CodexBridge", directoryHint: .isDirectory)
          .appending(path: "Service", directoryHint: .isDirectory)
        let first = try WindowsServicePaths.prepare(at: serviceRoot)
        XCTAssertEqual(first.databaseURL.lastPathComponent, "service.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: serviceRoot.path))
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: first.supervisorScratchURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.tunnelRuntimeURL.path))
        XCTAssertFalse(try WindowsServicePaths.prepare(at: serviceRoot).databaseURL.path.isEmpty)
      }
    }

    func testPrepareRejectsRelativeOrUNCRoots() {
      XCTAssertThrowsError(
        try WindowsServicePaths.prepare(at: URL(string: "relative/path")!)
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

    func testNonBasicAllowACETypesAreRejected() {
      for type: UInt8 in [0x04, 0x05, 0x09, 0x0B] {
        XCTAssertTrue(WindowsServicePaths.isNonBasicAllowACEType(type))
      }
      XCTAssertFalse(WindowsServicePaths.isNonBasicAllowACEType(0x00))
      XCTAssertFalse(WindowsServicePaths.isNonBasicAllowACEType(0x01))
    }

    func testObjectAllowACEIsRejected() throws {
      try withTempRoot { root in
        guard let currentUser = WindowsSecurity.currentUserSIDString()?.value else {
          throw XCTSkip("Current user SID unavailable")
        }
        let objectGUID = "00000000-0000-0000-0000-000000000001"
        let sddl = "O:\(currentUser)D:P(OA;;GA;\(objectGUID);;\(currentUser))"
        let directory = root.appending(path: "object-allow", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.applySDDL(sddl, to: directory.path)
        XCTAssertFalse(try WindowsServicePaths.hasTrustedProtection(directory.path))
      }
    }

    func testInvalidDriveRootIsRejectedBeforePreparation() {
      XCTAssertFalse(WindowsServicePaths.isFixedDrive("not-a-drive"))
      XCTAssertThrowsError(
        try WindowsServicePaths.prepare(
          at: URL(fileURLWithPath: "?:\\CodexBridge\\Service", isDirectory: true)
        )
      ) { error in
        XCTAssertEqual(error as? WindowsServicePaths.PathsError, .invalidRoot)
      }
    }

    func testDirectoryHandleLeaseBlocksRenameAndDeleteUntilReleased() throws {
      try withTempRoot { root in
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        let moved = root.appending(path: "moved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)

        try WindowsServicePaths.withDirectoryHandleLeaseForTesting(locked.path) {
          let renameResult = Self.moveDirectory(source: locked.path, destination: moved.path)
          XCTAssertFalse(renameResult.succeeded)
          XCTAssertEqual(renameResult.error, DWORD(32))  // ERROR_SHARING_VIOLATION

          let deleteWide = WideBuffer(locked.path)
          let deleteSucceeded = RemoveDirectoryW(deleteWide.pointer)
          let deleteError = GetLastError()
          XCTAssertFalse(deleteSucceeded)
          XCTAssertEqual(deleteError, DWORD(32))  // ERROR_SHARING_VIOLATION
        }

        XCTAssertTrue(Self.moveDirectory(source: locked.path, destination: moved.path).succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
      }
    }

    func testPrepareRejectsReparsePointAncestorWhenSymlinksAreAvailable() throws {
      try withTempRoot { root in
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appending(path: "ancestor-link", directoryHint: .isDirectory)
        guard Self.createSymlink(link: link.path, target: target.path) else {
          throw XCTSkip("Symbolic links require Developer Mode or privilege")
        }

        let requestedRoot =
          link
          .appending(path: "CodexBridge", directoryHint: .isDirectory)
          .appending(path: "Service", directoryHint: .isDirectory)
        XCTAssertThrowsError(try WindowsServicePaths.prepare(at: requestedRoot)) { error in
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

    private static func moveDirectory(
      source: String,
      destination: String
    ) -> (succeeded: Bool, error: DWORD) {
      let sourceWide = WideBuffer(source)
      let destinationWide = WideBuffer(destination)
      let succeeded = MoveFileExW(
        sourceWide.pointer,
        destinationWide.pointer,
        DWORD(0x0000_0008)  // MOVEFILE_WRITE_THROUGH
      )
      return (succeeded, GetLastError())
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
      var present = WindowsBool(false)
      var defaulted = WindowsBool(false)
      var dacl: PACL?
      guard GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted),
        present.boolValue, let dacl
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

    private func withTempRoot(_ body: (URL) throws -> Void) throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-bridge-paths-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try body(root)
    }
  }
#endif
