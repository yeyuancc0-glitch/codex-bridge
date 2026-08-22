import BridgePlatform
import XCTest

final class PlatformDiagnosticsTests: XCTestCase {
  private struct StubEnvironment: PlatformEnvironmentProviding {
    var processArchitecture: PlatformArchitecture = .arm64
    var nativeOSArchitecture: PlatformArchitecture = .arm64
  }

  func testDefaultsCoverRequiredComponentsWithUnknownRuntimeValues() {
    let diagnostics = PlatformDiagnostics(environment: StubEnvironment())
    XCTAssertEqual(
      diagnostics.architecture(forKey: PlatformDiagnostics.processArchKey),
      .arm64
    )
    XCTAssertEqual(
      diagnostics.architecture(forKey: PlatformDiagnostics.nativeOSArchKey),
      .arm64
    )
    for key in [
      PlatformDiagnostics.codexArchKey,
      PlatformDiagnostics.appServerArchKey,
      PlatformDiagnostics.tunnelArchKey,
      PlatformDiagnostics.webView2ArchKey,
    ] {
      XCTAssertEqual(diagnostics.architecture(forKey: key), .unknown)
    }
  }

  func testUnknownComponentKeysAreRejected() {
    var diagnostics = PlatformDiagnostics(environment: StubEnvironment())
    diagnostics.setArchitecture(forKey: "gpu_arch", architecture: .arm64)
    XCTAssertNil(diagnostics.architecture(forKey: "gpu_arch"))
    XCTAssertTrue(diagnostics.mismatchedRequiredComponents(requiring: ["gpu_arch": .amd64]).isEmpty)
  }

  func testMismatchedRequiredComponentsAreReported() {
    var diagnostics = PlatformDiagnostics(environment: StubEnvironment())
    diagnostics.setArchitecture(forKey: PlatformDiagnostics.tunnelArchKey, architecture: .amd64)
    XCTAssertEqual(
      diagnostics.mismatchedRequiredComponents(
        requiring: [PlatformDiagnostics.tunnelArchKey: .arm64]
      ),
      ["tunnel_arch=x86_64 expected arm64"]
    )
    XCTAssertTrue(
      diagnostics.mismatchedRequiredComponents(
        requiring: [PlatformDiagnostics.tunnelArchKey: .amd64]
      ).isEmpty
    )
  }

  func testUnresolvedRequiredComponentsAreNotReportedAsMismatches() {
    let diagnostics = PlatformDiagnostics(environment: StubEnvironment())
    XCTAssertTrue(
      diagnostics.mismatchedRequiredComponents(
        requiring: [PlatformDiagnostics.codexArchKey: .arm64]
      ).isEmpty
    )
  }
}

final class TargetPlatformArchitectureTests: XCTestCase {
  func testCurrentTargetArchitectureIsKnown() {
    XCTAssertNotEqual(TargetPlatformArchitecture.current, .unknown)
  }
}
