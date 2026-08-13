import BridgeSecurity
import BridgeTunnel
import Darwin
import Foundation

struct BundledDesktopTunnelManagerFactory: DesktopTunnelManagerBuilding {
  private static let helperRelativePath = "Contents/Helpers/tunnel-client"
  private static let digestRelativePath = "Contents/Helpers/tunnel-client.sha256"

  private let bundleURL: URL
  private let runtimeDirectory: URL
  private let secretStore: any SecretStore

  init(bundleURL: URL, dataDirectoryURL: URL, secretStore: any SecretStore) {
    self.bundleURL = bundleURL
    runtimeDirectory = dataDirectoryURL.appendingPathComponent("TunnelRuntime", isDirectory: true)
    self.secretStore = secretStore
  }

  func make(
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL: URL,
    localMCPHeaderSecret: String
  ) async throws -> any DesktopTunnelManaging {
    let helper = bundleURL.appendingPathComponent(Self.helperRelativePath)
    guard FileManager.default.isExecutableFile(atPath: helper.path) else {
      throw DesktopTransportError.helperUnavailable
    }
    let digestURL = bundleURL.appendingPathComponent(Self.digestRelativePath)
    let digest = try Self.readDigest(from: digestURL)
    let runtimeDirectory = try Self.preparePrivateRuntimeDirectory(runtimeDirectory)
    let configuration = try TunnelConfiguration(
      helperExecutable: helper,
      tunnelID: tunnelID,
      runtimeKeyReference: runtimeKeyReference,
      localMCPURL: localMCPURL,
      localMCPHeaderSecret: localMCPHeaderSecret,
      runtimeDirectory: runtimeDirectory,
      expectedHelperSHA256: digest
    )
    return TunnelManager(configuration: configuration, secretStore: secretStore)
  }

  private static func readDigest(from url: URL) throws -> String {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw DesktopTransportError.helperDigestUnavailable }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      (64...66).contains(metadata.st_size)
    else {
      throw DesktopTransportError.helperDigestUnavailable
    }
    var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
    let count = Darwin.read(descriptor, &bytes, bytes.count)
    guard count == bytes.count,
      let value = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      value.utf8.count == 64,
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      throw DesktopTransportError.helperDigestUnavailable
    }
    return value
  }

  private static func preparePrivateRuntimeDirectory(_ url: URL) throws -> URL {
    let parent = url.deletingLastPathComponent()
    let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentDescriptor >= 0 else { throw DesktopTransportError.helperUnavailable }
    defer { close(parentDescriptor) }
    let name = url.lastPathComponent
    if mkdirat(parentDescriptor, name, S_IRWXU) != 0, errno != EEXIST {
      throw DesktopTransportError.helperUnavailable
    }
    let descriptor = openat(
      parentDescriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw DesktopTransportError.helperUnavailable }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o777 == 0o700
    else {
      throw DesktopTransportError.helperUnavailable
    }
    return url
  }
}
