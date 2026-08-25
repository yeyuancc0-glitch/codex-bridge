import Foundation

public enum ACPJSONValue: Codable, Equatable, Sendable {
  case object([String: ACPJSONValue])
  case array([ACPJSONValue])
  case string(String)
  case integer(Int64)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([ACPJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: ACPJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var objectValue: [String: ACPJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [ACPJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    switch self {
    case .integer(let value): Int(exactly: value)
    case .number(let value) where value.rounded() == value: Int(exactly: value)
    default: nil
    }
  }

  public var doubleValue: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .number(let value): value
    default: nil
    }
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public subscript(_ key: String) -> ACPJSONValue? {
    objectValue?[key]
  }

  public func encodedData(sortedKeys: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    if sortedKeys { encoder.outputFormatting = [.sortedKeys] }
    return try encoder.encode(self)
  }

  public func encodedString(sortedKeys: Bool = true) -> String? {
    guard let data = try? encodedData(sortedKeys: sortedKeys) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

public enum ACPRequestID: Codable, Equatable, Hashable, Sendable {
  case integer(Int64)
  case string(String)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Int64.self) {
      self = .integer(value)
      return
    }
    self = .string(try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .integer(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    }
  }
}
