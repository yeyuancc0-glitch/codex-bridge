import BridgeSecurity
import BridgeTunnel
import Foundation

enum DefaultServiceTunnelManagerFactory {
  static func make(
    appBundleURL: URL?,
    runtimeDirectory: URL,
    secretStore: any SecretStore
  ) -> any ServiceTunnelManagerBuilding {
    #if canImport(Darwin)
      return BundledServiceTunnelManagerFactory(
        appBundleURL: appBundleURL ?? URL(fileURLWithPath: "/"),
        runtimeDirectory: runtimeDirectory,
        secretStore: secretStore
      )
    #else
      return UnavailableServiceTunnelManagerFactory()
    #endif
  }
}

struct UnavailableServiceTunnelManagerFactory: ServiceTunnelManagerBuilding {
  func helperAvailable() -> Bool { false }

  func make(
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async throws -> any ServiceTunnelManaging {
    _ = (tunnelID, runtimeKeyReference, localMCPURL, localMCPHeaderSecret)
    throw ServiceTunnelError.helperUnavailable
  }
}
