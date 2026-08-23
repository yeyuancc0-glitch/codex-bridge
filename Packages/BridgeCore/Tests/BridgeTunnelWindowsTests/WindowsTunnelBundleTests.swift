#if canImport(WinSDK)
  import BridgePlatformWindows
  import Foundation
  import XCTest

  @testable import BridgeTunnel

  final class WindowsTunnelBundleTests: XCTestCase {
    func testLoadsFixedHelperAndLowercaseDigestFromProtectedInstallRoot() throws {
      try withInstallRoot { root, fixture in
        let payload = root.appendingPathComponent("TunnelClient", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        let helper = payload.appendingPathComponent("tunnel-client.exe")
        try FileManager.default.copyItem(at: fixture, to: helper)
        let digest = String(repeating: "a", count: 64)
        try Data((digest + "\n").utf8).write(
          to: payload.appendingPathComponent("tunnel-client.sha256")
        )

        let bundle = try WindowsTunnelBundle(installDirectory: root)
        XCTAssertEqual(bundle.helperExecutable.path.lowercased(), helper.path.lowercased())
        XCTAssertEqual(bundle.expectedSHA256, digest)
      }
    }

    func testRejectsMissingPayloadAndNonLowercaseDigest() throws {
      try withInstallRoot { root, fixture in
        XCTAssertThrowsError(try WindowsTunnelBundle(installDirectory: root)) {
          XCTAssertEqual($0 as? WindowsTunnelBundleError, .missingPayload)
        }

        let payload = root.appendingPathComponent("TunnelClient", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        try FileManager.default.copyItem(
          at: fixture,
          to: payload.appendingPathComponent("tunnel-client.exe")
        )
        try Data(String(repeating: "A", count: 64).utf8).write(
          to: payload.appendingPathComponent("tunnel-client.sha256")
        )
        XCTAssertThrowsError(try WindowsTunnelBundle(installDirectory: root)) {
          XCTAssertEqual($0 as? WindowsTunnelBundleError, .invalidDigest)
        }
      }
    }

    private func withInstallRoot(
      _ body: (URL, URL) throws -> Void
    ) throws {
      guard let fixturePath = ProcessInfo.processInfo.environment["BRIDGE_WINDOWS_PROCESS_FIXTURE"]
      else {
        throw XCTSkip("BRIDGE_WINDOWS_PROCESS_FIXTURE is unavailable")
      }
      let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-bridge-tunnel-bundle-\(Foundation.UUID().uuidString)",
        isDirectory: true
      )
      let root = parent.appendingPathComponent("Install", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: parent) }
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
      _ = try WindowsServicePaths.prepare(at: root)
      try body(root, URL(fileURLWithPath: fixturePath))
    }
  }
#endif
