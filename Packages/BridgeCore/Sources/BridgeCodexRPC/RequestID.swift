import Foundation

public enum RequestID: Codable, Equatable, Hashable, Sendable {
  case integer(Int64)
  case string(String)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Int64.self) {
      self = .integer(value)
      return
    }
    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Request id must be an int64 or string"
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .integer(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }

  init(jsonValue: JSONValue) throws {
    switch jsonValue {
    case .integer(let value):
      self = .integer(value)
    case .string(let value):
      self = .string(value)
    default:
      throw CodexRPCError.malformedMessage("request id is not an int64 or string")
    }
  }

  var jsonValue: JSONValue {
    switch self {
    case .integer(let value): .integer(value)
    case .string(let value): .string(value)
    }
  }
}
