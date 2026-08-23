import Foundation
import Security

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
