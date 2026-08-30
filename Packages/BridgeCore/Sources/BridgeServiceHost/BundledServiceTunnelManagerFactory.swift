import BridgeSecurity
import BridgeTunnel
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

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
    let bytes = try readDigestBytes(from: url)
    guard
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

  private static func readDigestBytes(from url: URL) throws -> [UInt8] {
    #if os(Windows)
      let handle = url.path.withCString(encodedAs: UTF16.self) { path in
        CreateFileW(path, GENERIC_READ, 0, nil, DWORD(OPEN_EXISTING), 0, nil)
      }
      guard handle != INVALID_HANDLE_VALUE else {
        throw ServiceTunnelError.helperUnavailable
      }
      defer { _ = CloseHandle(handle) }
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &info) != 0,
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else {
        throw ServiceTunnelError.helperUnavailable
      }
      let size = Int((UInt64(info.nFileSizeHigh) << 32) | UInt64(info.nFileSizeLow))
      guard (64...66).contains(size) else {
        throw ServiceTunnelError.helperUnavailable
      }
      var bytes = [UInt8](repeating: 0, count: size)
      let complete = bytes.withUnsafeMutableBytes { raw -> Bool in
        var read: DWORD = 0
        return ReadFile(handle, raw.baseAddress, DWORD(size), &read, nil)
          && read == DWORD(size)
      }
      guard complete else {
        throw ServiceTunnelError.helperUnavailable
      }
      return bytes
    #else
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
      let count = read(descriptor, &bytes, bytes.count)
      guard count == bytes.count else {
        throw ServiceTunnelError.helperUnavailable
      }
      return bytes
    #endif
  }
}
