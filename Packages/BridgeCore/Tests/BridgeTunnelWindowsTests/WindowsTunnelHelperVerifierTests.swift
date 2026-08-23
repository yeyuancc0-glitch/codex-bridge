#if canImport(WinSDK)
  import BridgePlatform
  import Crypto
  import Foundation
  import WinSDK
  import XCTest

  @testable import BridgeTunnel

  final class WindowsTunnelHelperVerifierTests: XCTestCase {
    func testVerifiesNativePEAndCompleteDigest() throws {
      let helper = try helperURL()
      let data = try Data(contentsOf: helper)
      let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      let verified =
        try WindowsTunnelHelperVerifier().verify(
          executable: helper,
          expectedSHA256: expected,
          expectedArchitecture: TargetPlatformArchitecture.current
        ) != 0

      XCTAssertEqual(verified.sha256, expected)
      XCTAssertEqual(verified.executable.path.lowercased(), helper.path.lowercased())
      XCTAssertEqual(verified.identity.fileID.count, 16)
    }

    func testRejectsWrongDigestBeforeExecution() throws {
      let helper = try helperURL()
      XCTAssertThrowsError(
        try WindowsTunnelHelperVerifier().verify(
          executable: helper,
          expectedSHA256: String(repeating: "0", count: 64)
        )
      ) { error in
        XCTAssertEqual(error as? WindowsTunnelHelperError, .digestMismatch)
      }
    }

    func testRejectsArchitectureMismatchWithoutAllowingEmulation() throws {
      let helper = try helperURL()
      let current = TargetPlatformArchitecture.current
      let opposite: PlatformArchitecture
      switch current {
      case .amd64:
        opposite = .arm64
      case .arm64:
        opposite = .amd64
      case .unknown:
        throw XCTSkip("Unknown native Windows architecture")
      }
      let data = try Data(contentsOf: helper)
      let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

      XCTAssertThrowsError(
        try WindowsTunnelHelperVerifier().verify(
          executable: helper,
          expectedSHA256: expected,
          expectedArchitecture: opposite
        )
      ) { error in
        guard case .unsupportedArchitecture = error as? WindowsTunnelHelperError else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }

    func testRejectsRelativeAndUNCPaths() throws {
      let verifier = WindowsTunnelHelperVerifier()
      XCTAssertThrowsError(
        try verifier.verify(
          executable: URL(fileURLWithPath: "tunnel-client.exe"),
          expectedSHA256: String(repeating: "0", count: 64)
        )
      ) { error in
        XCTAssertEqual(error as? WindowsTunnelHelperError, .invalidPath)
      }
      XCTAssertThrowsError(
        try verifier.verify(
          executable: URL(
            fileURLWithPath: "\\\\server\\share\\tunnel-client.exe",
            isDirectory: false
          ),
          expectedSHA256: String(repeating: "0", count: 64)
        )
      ) { error in
        XCTAssertEqual(error as? WindowsTunnelHelperError, .networkPathDenied)
      }
    }

    func testRejectsReparseHelperWhenSymbolicLinksAreAvailable() throws {
      let helper = try helperURL()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "codex-bridge-tunnel-verifier-\(UUID().uuidString)",
          isDirectory: true
        )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let link = root.appendingPathComponent("helper.exe")
      guard Self.createSymbolicLink(link: link.path, target: helper.path) else {
        throw XCTSkip("Symbolic links require Developer Mode or privilege")
      }
      let data = try Data(contentsOf: helper)
      let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

      XCTAssertThrowsError(
        try WindowsTunnelHelperVerifier().verify(
          executable: link,
          expectedSHA256: expected
        )
      ) { error in
        XCTAssertEqual(error as? WindowsTunnelHelperError, .reparsePointDenied)
      }
    }

    private func helperURL() throws -> URL {
      guard
        let configured = ProcessInfo.processInfo.environment["BRIDGE_WINDOWS_TUNNEL_HELPER"]
      else {
        throw XCTSkip("Set BRIDGE_WINDOWS_TUNNEL_HELPER to a native .exe helper")
      }
      let url = URL(fileURLWithPath: configured).standardizedFileURL
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw XCTSkip("Configured Windows Tunnel helper does not exist")
      }
      return url
    }

    private static func createSymbolicLink(link: String, target: String) -> Bool {
      let linkWide = WideBuffer(link)
      let targetWide = WideBuffer(target)
      return CreateSymbolicLinkW(
        linkWide.pointer,
        targetWide.pointer,
        DWORD(0x2)  // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
      )
    }
  }
#endif
