import BridgeSecurity
import XCTest

@testable import BridgeTunnel

final class TunnelTypesTests: XCTestCase {
  func testTunnelIDAcceptsOnlyASCIIContract() throws {
    XCTAssertNoThrow(try TunnelID(validating: "tunnel_abcdefghijklmnopqrstuvwxyz012345"))
    XCTAssertThrowsError(try TunnelID(validating: "tunnel_abcdefghijklmnopqrstuvwxy０12345"))
    XCTAssertThrowsError(try TunnelID(validating: "tunnel_ABCDefghijklmnopqrstuvwxyz0123"))
  }

  func testLocalURLMustBeExactSecretEndpoint() throws {
    let reference = try SecretReference(validating: "runtime-key.test")
    let helper = URL(fileURLWithPath: "/tmp/helper")
    let runtime = URL(fileURLWithPath: "/tmp/runtime")
    let digest = String(repeating: "a", count: 64)
    let valid = URL(string: "http://127.0.0.1:4321/mcp/\(String(repeating: "A", count: 43))")!
    let configuration = try TunnelConfiguration(
      helperExecutable: helper,
      tunnelID: TunnelID(rawValue: "tunnel_abcdefghijklmnopqrstuvwxyz012345"),
      runtimeKeyReference: reference,
      localMCPURL: valid,
      runtimeDirectory: runtime,
      expectedHelperSHA256: digest
    )
    XCTAssertEqual(configuration.helperMCPURL.absoluteString, "http://127.0.0.1:4321/mcp")
    XCTAssertEqual(configuration.localMCPHeaderSecret, String(repeating: "A", count: 43))

    let headerConfiguration = try TunnelConfiguration(
      helperExecutable: helper,
      tunnelID: TunnelID(rawValue: "tunnel_abcdefghijklmnopqrstuvwxyz012345"),
      runtimeKeyReference: reference,
      localMCPURL: URL(string: "http://127.0.0.1:4321/mcp")!,
      localMCPHeaderSecret: String(repeating: "B", count: 43),
      runtimeDirectory: runtime,
      expectedHelperSHA256: digest
    )
    XCTAssertEqual(headerConfiguration.helperMCPURL, headerConfiguration.localMCPURL)
    XCTAssertEqual(headerConfiguration.localMCPHeaderSecret, String(repeating: "B", count: 43))
    for invalid in [
      "http://127.0.0.1:4321/other/\(String(repeating: "A", count: 43))",
      "http://localhost:4321/mcp/\(String(repeating: "A", count: 43))",
      "http://127.0.0.1:4321/mcp/%41\(String(repeating: "A", count: 42))",
    ] {
      XCTAssertThrowsError(
        try TunnelConfiguration(
          helperExecutable: helper,
          tunnelID: TunnelID(rawValue: "tunnel_abcdefghijklmnopqrstuvwxyz012345"),
          runtimeKeyReference: reference,
          localMCPURL: URL(string: invalid)!,
          runtimeDirectory: runtime,
          expectedHelperSHA256: digest
        )
      )
    }
  }

  func testCompanionRequiresCompleteValidPathAndDigest() throws {
    let reference = try SecretReference(validating: "runtime-key.test")
    let helper = URL(fileURLWithPath: "/tmp/helper")
    let runtime = URL(fileURLWithPath: "/tmp/runtime")
    let cloudflared = URL(fileURLWithPath: "/tmp/cloudflared")
    let digest = String(repeating: "a", count: 64)
    let tunnelID = TunnelID(rawValue: "tunnel_abcdefghijklmnopqrstuvwxyz012345")
    let localURL = URL(
      string: "http://127.0.0.1:4321/mcp/\(String(repeating: "A", count: 43))"
    )!

    let configuration = try TunnelConfiguration(
      helperExecutable: helper,
      tunnelID: tunnelID,
      runtimeKeyReference: reference,
      localMCPURL: localURL,
      runtimeDirectory: runtime,
      expectedHelperSHA256: digest,
      cloudflaredExecutable: cloudflared,
      expectedCloudflaredSHA256: digest
    )
    XCTAssertEqual(configuration.cloudflaredExecutable, cloudflared)
    XCTAssertEqual(configuration.expectedCloudflaredSHA256, digest)

    XCTAssertThrowsError(
      try TunnelConfiguration(
        helperExecutable: helper,
        tunnelID: tunnelID,
        runtimeKeyReference: reference,
        localMCPURL: localURL,
        runtimeDirectory: runtime,
        expectedHelperSHA256: digest,
        cloudflaredExecutable: cloudflared
      )
    ) {
      XCTAssertEqual($0 as? TunnelConfigurationError, .incompleteCompanion)
    }
  }
}
