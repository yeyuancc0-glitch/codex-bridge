#if canImport(WinSDK)
  import BridgeSecurity
  import BridgeTunnel
  import Foundation

  public struct BundledWindowsServiceTunnelManagerFactory: ServiceTunnelManagerBuilding {
    private let installDirectory: URL
    private let runtimeDirectory: URL
    private let secretStore: any SecretStore

    public init(
      installDirectory: URL,
      runtimeDirectory: URL,
      secretStore: any SecretStore
    ) {
      self.installDirectory = installDirectory.standardizedFileURL
      self.runtimeDirectory = runtimeDirectory.standardizedFileURL
      self.secretStore = secretStore
    }

    public func helperAvailable() -> Bool {
      (try? WindowsTunnelBundle(installDirectory: installDirectory)) != nil
    }

    public func make(
      tunnelID: TunnelID,
      runtimeKeyReference: SecretReference,
      localMCPURL: URL,
      localMCPHeaderSecret: String
    ) async throws -> any ServiceTunnelManaging {
      guard let bundle = try? WindowsTunnelBundle(installDirectory: installDirectory) else {
        throw ServiceTunnelError.helperUnavailable
      }
      let configuration = try TunnelConfiguration(
        helperExecutable: bundle.helperExecutable,
        tunnelID: tunnelID,
        runtimeKeyReference: runtimeKeyReference,
        localMCPURL: localMCPURL,
        localMCPHeaderSecret: localMCPHeaderSecret,
        runtimeDirectory: runtimeDirectory,
        expectedHelperSHA256: bundle.expectedSHA256,
        cloudflaredExecutable: bundle.cloudflaredExecutable,
        expectedCloudflaredSHA256: bundle.expectedCloudflaredSHA256
      )
      return TunnelManager(configuration: configuration, secretStore: secretStore)
    }
  }
#endif
