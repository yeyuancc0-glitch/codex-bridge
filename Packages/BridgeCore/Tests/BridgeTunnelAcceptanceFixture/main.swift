import BridgeSecurity
import BridgeTunnel
import Foundation

private struct FixtureSecretStore: SecretStore {
  let value: Data

  func store(_: Data, for _: SecretReference) throws {}
  func load(_: SecretReference) throws -> Data { value }
  func remove(_: SecretReference) throws {}
}

@main
private struct BridgeTunnelAcceptanceFixture {
  static func main() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 6 else {
      throw FixtureError.invalidArguments
    }
    let helper = URL(fileURLWithPath: arguments[1])
    let digest = arguments[2]
    let runtime = URL(fileURLWithPath: arguments[3], isDirectory: true)
    guard let localMCPURL = URL(string: arguments[4]) else {
      throw FixtureError.invalidArguments
    }
    let headerSecret = arguments[5]
    let reference = try SecretReference(validating: "tunnel.acceptance.fixture")
    let configuration = try TunnelConfiguration(
      helperExecutable: helper,
      tunnelID: try TunnelID(validating: "tunnel_abcdefghijklmnopqrstuvwxyz012345"),
      runtimeKeyReference: reference,
      localMCPURL: localMCPURL,
      localMCPHeaderSecret: headerSecret,
      runtimeDirectory: runtime,
      processTimeout: .seconds(20),
      expectedHelperSHA256: digest
    )
    let verifier = TunnelHelperVerifier(
      codeSignatureVerifier: MacOSTunnelCodeSignatureVerifier(requiresHostTeam: false)
    )
    let manager = TunnelManager(
      configuration: configuration,
      secretStore: FixtureSecretStore(value: Data("fixture_runtime_key_123".utf8)),
      helperVerifier: verifier
    )
    _ = try await manager.doctor()
  }
}

private enum FixtureError: Error {
  case invalidArguments
}
