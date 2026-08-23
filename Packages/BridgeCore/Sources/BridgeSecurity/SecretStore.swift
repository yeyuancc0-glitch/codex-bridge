import Foundation

public struct SecretReference: Hashable, RawRepresentable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    precondition(Self.isValid(rawValue), "Invalid secret reference")
    self.rawValue = rawValue
  }

  public init(validating rawValue: String) throws {
    guard Self.isValid(rawValue) else {
      throw SecretStoreError.invalidReference
    }
    self.rawValue = rawValue
  }

  public static func random(prefix: String) -> SecretReference {
    precondition(isValidPrefix(prefix), "Invalid secret reference prefix")
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
  case keychainFailure(Int32)
  case credentialStoreFailure(UInt32)
}

public protocol SecretStore: Sendable {
  func store(_ secret: Data, for reference: SecretReference) throws
  func load(_ reference: SecretReference) throws -> Data
  func remove(_ reference: SecretReference) throws
}

extension UInt8 {
  fileprivate var isASCIIAlphanumeric: Bool {
    (0x30...0x39).contains(self) || (0x41...0x5A).contains(self)
      || (0x61...0x7A).contains(self)
  }
}
