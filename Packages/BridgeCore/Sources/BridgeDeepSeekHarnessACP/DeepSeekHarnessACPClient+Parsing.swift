import BridgeACP
import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPClient {
  static func parseConfigOptions(_ value: ACPJSONValue?) throws
    -> [DeepSeekHarnessACPConfigOption]
  {
    guard let value else { return [] }
    guard let rawOptions = value.arrayValue, rawOptions.count <= 64 else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
    var seen = Set<String>()
    return try rawOptions.map { raw in
      guard let object = raw.objectValue,
        let id = object["id"]?.stringValue,
        seen.insert(id).inserted
      else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      try validateConfigText(id, maximumBytes: 256)
      let category = object["category"]?.stringValue
      if let category { try validateConfigText(category, maximumBytes: 64) }
      let currentValue = object["currentValue"]?.stringValue
      if let currentValue { try validateConfigText(currentValue, maximumBytes: 256) }
      guard let rawValues = object["options"]?.arrayValue, rawValues.count <= 512 else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      var seenValues = Set<String>()
      let values = try rawValues.map { rawValue -> DeepSeekHarnessACPConfigValue in
        guard let entry = rawValue.objectValue,
          let value = entry["value"]?.stringValue,
          let name = entry["name"]?.stringValue,
          seenValues.insert(value).inserted
        else {
          throw DeepSeekHarnessACPError.malformedResponse
        }
        try validateConfigText(value, maximumBytes: 256)
        try validateConfigText(name, maximumBytes: 512)
        return DeepSeekHarnessACPConfigValue(value: value, name: name)
      }
      return DeepSeekHarnessACPConfigOption(
        id: id,
        category: category,
        currentValue: currentValue,
        values: values
      )
    }
  }

  private static func validateConfigText(_ value: String, maximumBytes: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximumBytes, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
  }

  static func validateAbsolutePath(_ value: String, field: String) throws {
    guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  static func validateIdentifier(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  func validateAbsolutePath(_ value: String, field: String) throws {
    try Self.validateAbsolutePath(value, field: field)
  }

  func validateIdentifier(_ value: String, field: String) throws {
    try Self.validateIdentifier(value, field: field)
  }
}
