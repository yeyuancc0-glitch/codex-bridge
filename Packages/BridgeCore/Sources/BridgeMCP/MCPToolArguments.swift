import Foundation
import MCP

enum MCPToolAdapterError: Error {
  case invalidQueryOutput
}

struct StrictToolArguments {
  private let values: [String: Value]

  init(
    _ values: [String: Value]?,
    allowed: Set<String>,
    required: Set<String> = []
  ) throws {
    let values = values ?? [:]
    guard Set(values.keys).isSubset(of: allowed) else {
      throw MCPError.invalidParams("Unknown tool argument.")
    }
    guard required.allSatisfy({ values[$0] != nil && values[$0] != .null }) else {
      throw MCPError.invalidParams("A required tool argument is missing.")
    }
    self.values = values
  }

  func requiredIdentifier(_ key: String, maximumUTF8Bytes: Int) throws -> String {
    guard case .string(let value)? = values[key] else {
      throw MCPError.invalidParams("Argument '\(key)' must be a string.")
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      value == trimmed,
      !value.isEmpty,
      value.utf8.count <= maximumUTF8Bytes,
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw MCPError.invalidParams("Argument '\(key)' is invalid.")
    }
    return value
  }

  func requiredText(_ key: String, maximumUTF8Bytes: Int) throws -> String {
    let value = try text(key, maximumUTF8Bytes: maximumUTF8Bytes)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MCPError.invalidParams("Argument '\(key)' cannot be empty.")
    }
    return value
  }

  func text(_ key: String, maximumUTF8Bytes: Int) throws -> String {
    guard case .string(let value)? = values[key] else {
      throw MCPError.invalidParams("Argument '\(key)' must be a string.")
    }
    guard
      value.utf8.count <= maximumUTF8Bytes,
      value.rangeOfCharacter(from: .controlCharacters.subtracting(.newlines)) == nil
    else {
      throw MCPError.invalidParams("Argument '\(key)' must be bounded text.")
    }
    return value
  }

  func requiredBoolean(_ key: String) throws -> Bool {
    guard case .bool(let value)? = values[key] else {
      throw MCPError.invalidParams("Argument '\(key)' must be a boolean.")
    }
    return value
  }

  func optionalBoolean(_ key: String) throws -> Bool? {
    guard let value = values[key], value != .null else { return nil }
    guard case .bool(let result) = value else {
      throw MCPError.invalidParams("Argument '\(key)' must be a boolean.")
    }
    return result
  }

  func optionalNonnegativeInteger(_ key: String) throws -> Int64? {
    guard let value = values[key], value != .null else { return nil }
    guard case .int(let result) = value, result >= 0 else {
      throw MCPError.invalidParams("Argument '\(key)' must be a nonnegative integer.")
    }
    return Int64(result)
  }

  func optionalPositiveInteger(_ key: String, maximum: Int) throws -> Int? {
    guard let value = values[key], value != .null else { return nil }
    guard case .int(let result) = value, result > 0, result <= maximum else {
      throw MCPError.invalidParams("Argument '\(key)' must be a positive bounded integer.")
    }
    return result
  }

  func requiredObject(_ key: String) throws -> [String: Value] {
    guard case .object(let value)? = values[key] else {
      throw MCPError.invalidParams("Argument '\(key)' must be an object.")
    }
    return value
  }

  func stringArray(
    _ key: String,
    maximumCount: Int,
    maximumElementUTF8Bytes: Int
  ) throws -> [String] {
    guard case .array(let rawValues)? = values[key], rawValues.count <= maximumCount else {
      throw MCPError.invalidParams("Argument '\(key)' must be a bounded string array.")
    }
    return try rawValues.map { raw in
      guard case .string(let value) = raw,
        value.utf8.count <= maximumElementUTF8Bytes,
        value.rangeOfCharacter(from: .controlCharacters.subtracting(.newlines)) == nil
      else {
        throw MCPError.invalidParams("Argument '\(key)' must contain bounded text.")
      }
      return value
    }
  }

  func optionalString(_ key: String, maximumUTF8Bytes: Int) throws -> String? {
    guard let rawValue = values[key], rawValue != .null else { return nil }
    guard case .string(let value) = rawValue, value.utf8.count <= maximumUTF8Bytes,
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw MCPError.invalidParams("Argument '\(key)' must be a bounded string.")
    }
    return value
  }

  func optionalText(_ key: String, maximumUTF8Bytes: Int) throws -> String? {
    guard let rawValue = values[key], rawValue != .null else { return nil }
    return try text(key, maximumUTF8Bytes: maximumUTF8Bytes)
  }

  func optionalIdentifier(_ key: String, maximumUTF8Bytes: Int) throws -> String? {
    guard let value = try optionalString(key, maximumUTF8Bytes: maximumUTF8Bytes) else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value == trimmed, !value.isEmpty else {
      throw MCPError.invalidParams("Argument '\(key)' is invalid.")
    }
    return value
  }

  func optionalStringArray(
    _ key: String,
    maximumCount: Int,
    maximumElementUTF8Bytes: Int
  ) throws -> [String] {
    guard let value = values[key], value != .null else { return [] }
    guard case .array(let rawValues) = value, rawValues.count <= maximumCount else {
      throw MCPError.invalidParams("Argument '\(key)' must be a bounded string array.")
    }
    return try rawValues.map { raw in
      guard case .string(let text) = raw,
        text.utf8.count <= maximumElementUTF8Bytes,
        text.rangeOfCharacter(from: .controlCharacters.subtracting(.newlines)) == nil
      else {
        throw MCPError.invalidParams("Argument '\(key)' must contain bounded text.")
      }
      return text
    }
  }

  func limit() throws -> Int {
    try limit(maximum: 100)
  }

  func limit(maximum: Int) throws -> Int {
    guard let value = values["limit"], value != .null else { return 25 }
    guard case .int(let limit) = value, (1...maximum).contains(limit) else {
      throw MCPError.invalidParams(
        "Argument 'limit' must be an integer from 1 through \(maximum)."
      )
    }
    return limit
  }

  func threadDetail() throws -> MCPThreadDetail {
    guard let value = values["detail"], value != .null else { return .summary }
    guard case .string(let rawValue) = value, let detail = MCPThreadDetail(rawValue: rawValue)
    else {
      throw MCPError.invalidParams("Argument 'detail' must be 'summary' or 'full'.")
    }
    return detail
  }
}
