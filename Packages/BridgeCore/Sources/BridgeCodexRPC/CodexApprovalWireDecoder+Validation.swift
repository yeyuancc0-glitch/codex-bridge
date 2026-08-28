import Foundation

extension CodexApprovalWireDecoder {
  static func validate(requestID: RequestID) throws {
    guard case .string(let value) = requestID else { return }
    try validateString(
      value, field: "requestId", maximumBytes: CodexApprovalWireLimits.identifierBytes)
    guard !value.isEmpty else { throw CodexApprovalWireError.invalidField("requestId") }
  }

  static func identifier(
    _ object: [String: JSONValue],
    key: String
  ) throws -> String {
    let value = try requiredString(
      object, key: key, maximumBytes: CodexApprovalWireLimits.identifierBytes)
    guard !value.isEmpty else { throw CodexApprovalWireError.invalidField(key) }
    return value
  }

  static func optionalIdentifier(
    _ object: [String: JSONValue],
    key: String
  ) throws -> String? {
    guard
      let value = try optionalString(
        object, key: key, maximumBytes: CodexApprovalWireLimits.identifierBytes)
    else { return nil }
    guard !value.isEmpty else { throw CodexApprovalWireError.invalidField(key) }
    return value
  }

  static func requiredString(
    _ object: [String: JSONValue],
    key: String,
    maximumBytes: Int = CodexApprovalWireLimits.stringBytes
  ) throws -> String {
    guard let value = object[key] else { throw CodexApprovalWireError.missingField(key) }
    guard case .string(let string) = value else {
      throw CodexApprovalWireError.invalidField(key)
    }
    try validateString(string, field: key, maximumBytes: maximumBytes)
    return string
  }

  static func optionalString(
    _ object: [String: JSONValue],
    key: String,
    maximumBytes: Int = CodexApprovalWireLimits.stringBytes
  ) throws -> String? {
    guard let value = object[key], value != .null else { return nil }
    guard case .string(let string) = value else {
      throw CodexApprovalWireError.invalidField(key)
    }
    try validateString(string, field: key, maximumBytes: maximumBytes)
    return string
  }

  static func validateString(
    _ value: String,
    field: String,
    maximumBytes: Int
  ) throws {
    guard value.utf8.count <= maximumBytes else {
      throw CodexApprovalWireError.stringTooLarge(field: field, maximumBytes: maximumBytes)
    }
    guard !value.contains("\0") else { throw CodexApprovalWireError.invalidField(field) }
  }

  static func requiredInteger(
    _ object: [String: JSONValue],
    key: String
  ) throws -> Int64 {
    guard let value = object[key] else { throw CodexApprovalWireError.missingField(key) }
    guard case .integer(let integer) = value else {
      throw CodexApprovalWireError.invalidField(key)
    }
    return integer
  }

  static func optionalUnsignedInteger(
    _ object: [String: JSONValue],
    key: String
  ) throws -> UInt? {
    guard let value = object[key], value != .null else { return nil }
    guard case .integer(let integer) = value, integer >= 0, let converted = UInt(exactly: integer)
    else {
      throw CodexApprovalWireError.invalidField(key)
    }
    return converted
  }

  static func optionalInt32(
    _ object: [String: JSONValue],
    key: String
  ) throws -> Int32? {
    guard let value = object[key], value != .null else { return nil }
    guard case .integer(let integer) = value, let converted = Int32(exactly: integer) else {
      throw CodexApprovalWireError.invalidField(key)
    }
    return converted
  }

  static func optionalBool(
    _ object: [String: JSONValue],
    key: String
  ) throws -> Bool? {
    guard let value = object[key], value != .null else { return nil }
    guard case .bool(let boolean) = value else {
      throw CodexApprovalWireError.invalidField(key)
    }
    return boolean
  }

  static func optionalStringArray(
    _ value: JSONValue?,
    field: String
  ) throws -> [String]? {
    guard value != nil, value != .null else { return nil }
    let values = try array(value, field: field)
    try validateArray(values, field: field)
    return try values.enumerated().map { index, value in
      guard case .string(let string) = value else {
        throw CodexApprovalWireError.invalidField("\(field)[\(index)]")
      }
      try validateString(
        string,
        field: "\(field)[\(index)]",
        maximumBytes: CodexApprovalWireLimits.stringBytes
      )
      return string
    }
  }

  static func object(
    _ value: JSONValue?,
    field: String
  ) throws -> [String: JSONValue] {
    guard let value else { throw CodexApprovalWireError.missingField(field) }
    guard case .object(let object) = value else {
      throw CodexApprovalWireError.invalidField(field)
    }
    return object
  }

  static func array(
    _ value: JSONValue?,
    field: String
  ) throws -> [JSONValue] {
    guard let value else { throw CodexApprovalWireError.missingField(field) }
    guard case .array(let array) = value else {
      throw CodexApprovalWireError.invalidField(field)
    }
    return array
  }

  static func validateArray(_ values: [JSONValue], field: String) throws {
    guard values.count <= CodexApprovalWireLimits.arrayCount else {
      throw CodexApprovalWireError.arrayTooLarge(
        field: field,
        maximumCount: CodexApprovalWireLimits.arrayCount
      )
    }
  }

  static func requireOnlyKeys(
    _ object: [String: JSONValue],
    allowed: Set<String>,
    context: String
  ) throws {
    guard let unknown = object.keys.first(where: { !allowed.contains($0) }) else { return }
    throw CodexApprovalWireError.unknownField(context: context, field: unknown)
  }

  static func enumValue<Value: RawRepresentable>(
    _ rawValue: String,
    field: String,
    as _: Value.Type
  ) throws -> Value where Value.RawValue == String {
    guard let value = Value(rawValue: rawValue) else {
      throw CodexApprovalWireError.unknownDiscriminator(field: field, value: rawValue)
    }
    return value
  }

  static func validateEvidenceSize(_ value: JSONValue?) throws {
    guard let value else { throw CodexApprovalWireError.missingField("params") }
    let data: Data
    do {
      data = try JSONEncoder().encode(value)
    } catch {
      throw CodexApprovalWireError.invalidField("params")
    }
    guard data.count <= CodexApprovalWireLimits.totalEvidenceBytes else {
      throw CodexApprovalWireError.evidenceTooLarge(
        maximumBytes: CodexApprovalWireLimits.totalEvidenceBytes)
    }
  }

  static func isNormalizedAbsolutePath(_ value: String) -> Bool {
    guard value.hasPrefix("/"), value == "/" || !value.hasSuffix("/") else { return false }
    if value.contains("//") || value.contains("/./") || value.contains("/../") { return false }
    return !value.hasSuffix("/.") && !value.hasSuffix("/..")
  }
}
