#if canImport(WinSDK)
  import XCTest

  @testable import BridgeTunnel

  final class WindowsTunnelProcessLauncherTests: XCTestCase {
    func testRewritesOnlySecretFileReferencesWithoutPuttingSecretsInArguments() throws {
      let arguments = [
        "run",
        "--control-plane.api-key=file:/dev/fd/3",
        "--mcp.extra-headers",
        "X-Codex-Bridge-Token: file:/dev/fd/4",
      ]
      let rewritten = try XCTUnwrap(
        WindowsTunnelProcessLauncher.rewriteSecretArguments(
          arguments,
          runtimeKeyPath: "C:\\runtime\\runtime.key",
          headerSecretPath: "C:\\runtime\\mcp-header.key"
        )
      )
      XCTAssertEqual(
        rewritten,
        [
          "run",
          "--control-plane.api-key=file:C:\\runtime\\runtime.key",
          "--mcp.extra-headers",
          "X-Codex-Bridge-Token: file:C:\\runtime\\mcp-header.key",
        ]
      )
      XCTAssertFalse(rewritten.joined().contains("runtime-secret"))
      XCTAssertFalse(rewritten.joined().contains("header-secret"))
    }

    func testRejectsArgumentsMissingEitherSecretReference() {
      XCTAssertNil(
        WindowsTunnelProcessLauncher.rewriteSecretArguments(
          ["run", "--control-plane.api-key=file:/dev/fd/3"],
          runtimeKeyPath: "C:\\runtime.key",
          headerSecretPath: "C:\\header.key"
        )
      )
    }
  }
#endif
