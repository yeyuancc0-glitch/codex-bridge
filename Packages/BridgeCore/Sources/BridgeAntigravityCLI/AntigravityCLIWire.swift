import Foundation

public enum AntigravityCLIError: Error, Equatable, Sendable {
  case invalidMessage
  case oversizedFrame
  case transportClosed
  case processExited(Int32?)
  case requestTimedOut
  case sessionMismatch
  case modelMismatch(String)
  case unsupportedVersion(String)
  case permissionDenied
}

public enum AntigravityJSONValue: Codable, Equatable, Sendable {
  case object([String: AntigravityJSONValue])
  case array([AntigravityJSONValue])
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
    } else if let value = try? container.decode([AntigravityJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: AntigravityJSONValue].self))
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

  public var objectValue: [String: AntigravityJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [AntigravityJSONValue]? {
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

  public subscript(_ key: String) -> AntigravityJSONValue? {
    objectValue?[key]
  }

  public func encodedString() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

public struct AntigravityUsage: Codable, Equatable, Sendable {
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let thinkingTokens: Int?
  public let cacheReadTokens: Int?
  public let totalTokens: Int?

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case thinkingTokens = "thinking_tokens"
    case cacheReadTokens = "cache_read_tokens"
    case totalTokens = "total_tokens"
  }
}

public struct AntigravityToolError: Codable, Equatable, Sendable {
  public let type: String?
  public let message: String?
}

public struct AntigravityToolInfo: Codable, Equatable, Sendable {
  public let name: String?
  public let parameters: AntigravityJSONValue?
  public let output: String?
  public let error: AntigravityToolError?
}

public struct AntigravitySubagent: Codable, Equatable, Sendable {
  public let typeName: String?
  public let role: String?
  public let conversationID: String?
  public let logURI: String?
  public let workspaceURIs: [String]?

  private enum CodingKeys: String, CodingKey {
    case typeName = "type_name"
    case role
    case conversationID = "conversation_id"
    case logURI = "log_uri"
    case workspaceURIs = "workspace_uris"
  }
}

public struct AntigravitySubagentInfo: Codable, Equatable, Sendable {
  public let subagents: [AntigravitySubagent]?
}

public struct AntigravityInitialization: Codable, Equatable, Sendable {
  public let cwd: String
  public let tools: [String]
  public let permissionMode: String
  public let model: String?
  public let agent: String?

  private enum CodingKeys: String, CodingKey {
    case cwd
    case tools
    case permissionMode = "permission_mode"
    case model
    case agent
  }
}

public struct AntigravityStepUpdate: Codable, Equatable, Sendable {
  public let conversationID: String
  public let stepIndex: Int
  public let state: String
  public let stepType: String
  public let toolName: String?
  public let textDelta: String?
  public let durationSeconds: Double?
  public let usage: AntigravityUsage?
  public let toolInfo: AntigravityToolInfo?
  public let error: AntigravityToolError?
  public let subagentInfo: AntigravitySubagentInfo?

  private enum CodingKeys: String, CodingKey {
    case conversationID = "conversation_id"
    case stepIndex = "step_index"
    case state
    case stepType = "step_type"
    case toolName = "tool_name"
    case textDelta = "text_delta"
    case durationSeconds = "duration_seconds"
    case usage
    case toolInfo = "tool_info"
    case error
    case subagentInfo = "subagent_info"
  }
}

public struct AntigravityResult: Codable, Equatable, Sendable {
  public let conversationID: String
  public let status: String
  public let response: String
  public let error: String?
  public let durationSeconds: Double?
  public let numTurns: Int?
  public let usage: AntigravityUsage?

  private enum CodingKeys: String, CodingKey {
    case conversationID = "conversation_id"
    case status
    case response
    case error
    case durationSeconds = "duration_seconds"
    case numTurns = "num_turns"
    case usage
  }
}

public struct AntigravityStreamEnvelope: Codable, Equatable, Sendable {
  public let event: String
  public let conversationID: String?
  public let initialization: AntigravityInitialization?
  public let stepUpdate: AntigravityStepUpdate?
  public let result: AntigravityResult?

  private enum CodingKeys: String, CodingKey {
    case event
    case conversationID = "conversation_id"
    case initialization = "init"
    case stepUpdate = "step_update"
    case result
  }

  public init(
    event: String,
    conversationID: String? = nil,
    initialization: AntigravityInitialization? = nil,
    stepUpdate: AntigravityStepUpdate? = nil,
    result: AntigravityResult? = nil
  ) {
    self.event = event
    self.conversationID = conversationID
    self.initialization = initialization
    self.stepUpdate = stepUpdate
    self.result = result
  }
}

public struct AntigravityUserMessage: Codable, Equatable, Sendable {
  public let event: String
  public let message: Message

  public struct Message: Codable, Equatable, Sendable {
    public let content: String
  }

  public init(content: String) {
    event = "user"
    message = Message(content: content)
  }
}

public enum AntigravityWireCodec {
  public static func decode(_ data: Data, maximumBytes: Int = 1_048_576) throws
    -> AntigravityStreamEnvelope
  {
    guard !data.isEmpty, data.count <= maximumBytes else {
      throw AntigravityCLIError.oversizedFrame
    }
    do {
      return try JSONDecoder().decode(AntigravityStreamEnvelope.self, from: data)
    } catch {
      throw AntigravityCLIError.invalidMessage
    }
  }

  public static func encodeUserMessage(_ content: String, maximumBytes: Int = 64 * 1_024) throws
    -> Data
  {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes, !trimmed.contains("\0") else {
      throw AntigravityCLIError.invalidMessage
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(AntigravityUserMessage(content: trimmed))
    guard data.count <= maximumBytes + 1_024 else {
      throw AntigravityCLIError.oversizedFrame
    }
    return data
  }
}
