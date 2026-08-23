#if canImport(Darwin)
  import BridgeSecurity
  import BridgeTunnel
  import Darwin
  import Foundation

  public struct BundledServiceTunnelManagerFactory: ServiceTunnelManagerBuilding {
    private static let helperRelativePath = "Contents/Helpers/tunnel-client"
    private static let digestRelativePath = "Contents/Resources/TunnelClient/tunnel-client.sha256"

    private let appBundleURL: URL
    private let runtimeDirectory: URL
    private let secretStore: any SecretStore

    public init(
      appBundleURL: URL,
      runtimeDirectory: URL,
      secretStore: any SecretStore
    ) {
      self.appBundleURL = appBundleURL.standardizedFileURL
      self.runtimeDirectory = runtimeDirectory.standardizedFileURL
      self.secretStore = secretStore
    }

    public func helperAvailable() -> Bool {
      let helper = helperURL
      let digest = digestURL
      return FileManager.default.isExecutableFile(atPath: helper.path)
        && FileManager.default.fileExists(atPath: digest.path)
    }

    public func make(
      tunnelID: TunnelID,
      runtimeKeyReference: SecretReference,
      localMCPURL: URL,
      localMCPHeaderSecret: String
    ) async throws -> any ServiceTunnelManaging {
      guard helperAvailable() else { throw ServiceTunnelError.helperUnavailable }
      let digest = try Self.readDigest(from: digestURL)
      let configuration = try TunnelConfiguration(
        helperExecutable: helperURL,
        tunnelID: tunnelID,
        runtimeKeyReference: runtimeKeyReference,
        localMCPURL: localMCPURL,
        localMCPHeaderSecret: localMCPHeaderSecret,
        runtimeDirectory: runtimeDirectory,
        expectedHelperSHA256: digest
      )
      return TunnelManager(configuration: configuration, secretStore: secretStore)
    }

    private var helperURL: URL {
      appBundleURL.appending(path: Self.helperRelativePath)
    }

    private var digestURL: URL {
      appBundleURL.appending(path: Self.digestRelativePath)
    }

    private static func readDigest(from url: URL) throws -> String {
      let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw ServiceTunnelError.helperUnavailable }
      defer { close(descriptor) }

      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFREG,
        (64...66).contains(metadata.st_size)
      else {
        throw ServiceTunnelError.helperUnavailable
      }

      var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      guard count == bytes.count,
        let value = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines
        ),
        value.utf8.count == 64,
        value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else {
        throw ServiceTunnelError.helperUnavailable
      }
      return value
    }
  }
#endif
