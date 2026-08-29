import Foundation
#if canImport(Security)
  import Security
#endif

public struct SecretReference: Hashable, RawRepresentable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    precondition(Self.isValid(rawValue), "Invalid Keychain secret reference")
    self.rawValue = rawValue
  }

  public init(validating rawValue: String) throws {
    guard Self.isValid(rawValue) else {
      throw SecretStoreError.invalidReference
    }
    self.rawValue = rawValue
  }

  public static func random(prefix: String) -> SecretReference {
    precondition(isValidPrefix(prefix), "Invalid Keychain secret reference prefix")
    return SecretReference(rawValue: "\(prefix).\(UUID().uuidString.lowercased())")
  }

  public static func runtimeKey(profileID: UUID) -> SecretReference {
    SecretReference(rawValue: "tunnel-runtime-key.\(profileID.uuidString.lowercased())")
  }

  public static func mcpPathSecret(profileID: UUID) -> SecretReference {
    SecretReference(rawValue: "mcp-path-secret.\(profileID.uuidString.lowercased())")
  }

  private static func isValid(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    return value.utf8.allSatisfy { byte in
      byte.isASCIIAlphanumeric || byte == 0x2D || byte == 0x2E || byte == 0x5F
    }
  }

  private static func isValidPrefix(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 80 && isValid(value)
  }
}

public enum SecretStoreError: Error, Equatable, Sendable {
  case invalidReference
  case invalidSecret
  case notFound
  case accessDenied
  case invalidStoredValue
  case keychainFailure(OSStatus)
}

public protocol SecretStore: Sendable {
  func store(_ secret: Data, for reference: SecretReference) throws
  func load(_ reference: SecretReference) throws -> Data
  func remove(_ reference: SecretReference) throws
}

#if canImport(Security)
  public struct KeychainSecretStore: SecretStore, Sendable {
    public static let defaultService = "com.openai.codex-bridge.secrets"
    public static let maximumSecretBytes = 16 * 1024

    private let service: String

    public init(service: String = Self.defaultService) {
      precondition(!service.isEmpty && service.utf8.count <= 255)
      self.service = service
    }

    public func store(_ secret: Data, for reference: SecretReference) throws {
      guard !secret.isEmpty, secret.count <= Self.maximumSecretBytes else {
        throw SecretStoreError.invalidSecret
      }

      let attributes = [kSecValueData: secret] as CFDictionary
      var status = SecItemUpdate(baseQuery(reference) as CFDictionary, attributes)
      if status == errSecSuccess { return }
      guard status == errSecItemNotFound else { throw map(status) }

      var item = baseQuery(reference)
      item[kSecValueData] = secret
      item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
      if status == errSecDuplicateItem {
        status = SecItemUpdate(baseQuery(reference) as CFDictionary, attributes)
      }
      guard status == errSecSuccess else { throw map(status) }
    }

    public func load(_ reference: SecretReference) throws -> Data {
      var query = baseQuery(reference)
      query[kSecReturnData] = true
      query[kSecMatchLimit] = kSecMatchLimitOne

      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      guard status == errSecSuccess else { throw map(status) }
      guard let data = result as? Data, !data.isEmpty, data.count <= Self.maximumSecretBytes else {
        throw SecretStoreError.invalidStoredValue
      }
      return data
    }

    public func remove(_ reference: SecretReference) throws {
      let status = SecItemDelete(baseQuery(reference) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw map(status)
      }
    }

    private func baseQuery(_ reference: SecretReference) -> [CFString: Any] {
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: reference.rawValue,
        kSecAttrSynchronizable: false,
      ]
    }

    private func map(_ status: OSStatus) -> SecretStoreError {
      switch status {
      case errSecItemNotFound:
        return .notFound
      case errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable:
        return .accessDenied
      default:
        return .keychainFailure(status)
      }
    }
  }
#endif

extension UInt8 {
  fileprivate var isASCIIAlphanumeric: Bool {
    (0x30...0x39).contains(self) || (0x41...0x5A).contains(self)
      || (0x61...0x7A).contains(self)
  }
}
