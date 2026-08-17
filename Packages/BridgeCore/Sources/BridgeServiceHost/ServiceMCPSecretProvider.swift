import BridgeSecurity
import Foundation
import Security

public enum ServiceMCPSecretError: Error, Equatable, Sendable {
  case randomGenerationFailed
  case invalidStoredSecret
}

public actor ServiceMCPSecretProvider {
  public static let reference = SecretReference(rawValue: "service-mcp-path-secret")

  private let store: any SecretStore
  private let randomBytes: @Sendable (Int) throws -> Data

  public init(store: any SecretStore = KeychainSecretStore()) {
    self.store = store
    randomBytes = Self.secureRandomBytes
  }

  public init(
    store: any SecretStore,
    randomBytes: @escaping @Sendable (Int) throws -> Data
  ) {
    self.store = store
    self.randomBytes = randomBytes
  }

  public func secret() throws -> String {
    do {
      let data = try store.load(Self.reference)
      guard let value = String(data: data, encoding: .utf8), Self.isValid(value) else {
        throw ServiceMCPSecretError.invalidStoredSecret
      }
      return value
    } catch SecretStoreError.notFound {
      let value = try Self.encode(randomBytes(32))
      try store.store(Data(value.utf8), for: Self.reference)
      return value
    }
  }

  public func rotate() throws -> String {
    let value = try Self.encode(randomBytes(32))
    try store.store(Data(value.utf8), for: Self.reference)
    return value
  }

  private static func secureRandomBytes(count: Int) throws -> Data {
    guard count > 0, count <= 4_096 else {
      throw ServiceMCPSecretError.randomGenerationFailed
    }
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
      throw ServiceMCPSecretError.randomGenerationFailed
    }
    return Data(bytes)
  }

  private static func encode(_ data: Data) throws -> String {
    guard data.count == 32 else { throw ServiceMCPSecretError.randomGenerationFailed }
    let value = data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    guard isValid(value) else { throw ServiceMCPSecretError.randomGenerationFailed }
    return value
  }

  private static func isValid(_ value: String) -> Bool {
    value.utf8.count == 43
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || byte == 45
          || byte == 95
      }
  }
}
