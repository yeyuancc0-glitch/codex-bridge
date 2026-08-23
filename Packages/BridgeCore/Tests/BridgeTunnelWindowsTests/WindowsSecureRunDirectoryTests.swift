#if canImport(WinSDK)
  import BridgePlatformWindows
  import Foundation
  import WinSDK
  import XCTest

  @testable import BridgeTunnel

  final class WindowsSecureRunDirectoryTests: XCTestCase {
    func testProtectedRootCreatesFixedRunEntriesAndReadsRegularFiles() throws {
      try withServicePaths { paths in
        let root = try WindowsSecureRunDirectory(existingRoot: paths.tunnelRuntimeURL)
        let name = "r-\(UUID().uuidString)"
        let run = try WindowsSecureRunDirectory(creating: name, in: root)
        XCTAssertTrue(root.matchesPath())
        XCTAssertTrue(run.matchesPath())
        XCTAssertTrue(root.contains(name: name, directory: run))

        try run.createDirectory(name: "codex-home")
        let file = URL(fileURLWithPath: run.path).appendingPathComponent("health.url")
        try Data("http://127.0.0.1:43210".utf8).write(to: file)
        XCTAssertEqual(
          try run.readRegularFile(name: "health.url", maximumBytes: 2_048),
          Data("http://127.0.0.1:43210".utf8)
        )

        try run.removeEntry(name: "health.url")
        try run.removeEntry(name: "codex-home", directory: true)
        try root.removeEntry(name: name, directory: true)
        XCTAssertFalse(root.contains(name: name, directory: run))
      }
    }

    func testRejectsUnsafeNamesAndReparseEntries() throws {
      try withServicePaths { paths in
        let root = try WindowsSecureRunDirectory(existingRoot: paths.tunnelRuntimeURL)
        for name in ["..", "bad:name", "CON", "name."] {
          XCTAssertThrowsError(try WindowsSecureRunDirectory(creating: name, in: root), name)
        }

        let run = try WindowsSecureRunDirectory(creating: "r-\(UUID().uuidString)", in: root)
        let target = URL(fileURLWithPath: run.path).appendingPathComponent("target.txt")
        try Data("target".utf8).write(to: target)
        let link = URL(fileURLWithPath: run.path).appendingPathComponent("health.url")
        guard Self.createSymbolicLink(link: link.path, target: target.path) else {
          throw XCTSkip("Symbolic links require Developer Mode or privilege")
        }

        XCTAssertThrowsError(try run.readRegularFile(name: "health.url", maximumBytes: 2_048)) {
          XCTAssertEqual($0 as? WindowsSecureRunDirectoryError, .reparsePointDenied)
        }
        XCTAssertThrowsError(try run.removeEntry(name: "health.url")) {
          XCTAssertEqual($0 as? WindowsSecureRunDirectoryError, .reparsePointDenied)
        }
      }
    }

    func testRejectsDirectoryWithEveryoneAllowACE() throws {
      try withServicePaths { paths in
        let insecure = paths.tunnelRuntimeURL.appendingPathComponent("insecure")
        try FileManager.default.createDirectory(at: insecure, withIntermediateDirectories: false)
        try Self.applySDDL("D:P(A;;GA;;;WD)", to: insecure.path)

        XCTAssertThrowsError(try WindowsSecureRunDirectory(existingRoot: insecure)) {
          XCTAssertEqual($0 as? WindowsSecureRunDirectoryError, .insecureDirectory)
        }
      }
    }

    private func withServicePaths(_ body: (WindowsServicePaths) throws -> Void) rethrows {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "codex-bridge-tunnel-runtime-\(UUID().uuidString)",
          isDirectory: true
        )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      try body(try WindowsServicePaths.prepare(at: root))
    }

    private static func applySDDL(_ sddl: String, to path: String) throws {
      var descriptor: UnsafeMutableRawPointer?
      let wide = WideBuffer(sddl)
      guard
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
          wide.pointer,
          DWORD(1),
          &descriptor,
          nil
        ),
        let descriptor
      else {
        throw XCTSkip("SDDL conversion failed: \(GetLastError())")
      }
      defer { LocalFree(descriptor) }

      var present = WindowsBool(0)
      var defaulted = WindowsBool(0)
      var dacl: PACL?
      guard GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted), let dacl else {
        throw XCTSkip("GetSecurityDescriptorDacl failed: \(GetLastError())")
      }
      let pathWide = WideBuffer(path)
      guard
        SetNamedSecurityInfoW(
          pathWide.pointer,
          SE_OBJECT_TYPE(rawValue: Int32(1)),
          DWORD(0x0000_0004),  // DACL_SECURITY_INFORMATION
          nil,
          nil,
          dacl,
          nil
        ) == DWORD(ERROR_SUCCESS)
      else {
        throw XCTSkip("SetNamedSecurityInfoW failed: \(GetLastError())")
      }
    }

    private static func createSymbolicLink(link: String, target: String) -> Bool {
      let linkWide = WideBuffer(link)
      let targetWide = WideBuffer(target)
      return CreateSymbolicLinkW(
        linkWide.pointer,
        targetWide.pointer,
        DWORD(0x2)  // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
      ) != 0
    }
  }
#endif
