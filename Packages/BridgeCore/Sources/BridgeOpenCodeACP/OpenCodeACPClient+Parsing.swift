import BridgeACP
import BridgeAgentCore
import Foundation

extension OpenCodeACPClient {
  static func parseInitialization(_ value: ACPJSONValue) throws
    -> OpenCodeACPInitialization
  {
    guard let object = value.objectValue,
      let protocolVersion = object["protocolVersion"]?.intValue
    else {
      throw OpenCodeACPError.malformedResponse
    }
    let capabilities = object["agentCapabilities"]?.objectValue ?? [:]
    let sessionCapabilities = capabilities["sessionCapabilities"]?.objectValue ?? [:]
    let load = capabilities["loadSession"]?.boolValue == true
    let resume = sessionCapabilities["resume"] != nil
    let close = sessionCapabilities["close"] != nil
    let info = object["agentInfo"]?.objectValue

    var advertised: Set<AgentCapability> = [
      .sessionCreate,
      .interrupt,
      .textDelta,
      .toolLifecycle,
    ]
    if load || resume { advertised.insert(.sessionContinue) }

    return OpenCodeACPInitialization(
      protocolVersion: protocolVersion,
      agentName: info?["name"]?.stringValue,
      agentTitle: info?["title"]?.stringValue,
      agentVersion: info?["version"]?.stringValue,
      advertisedCapabilities: advertised,
      supportsLoadSession: load,
      supportsResumeSession: resume,
      supportsCloseSession: close
    )
  }

  static func parseSession(
    _ value: ACPJSONValue,
    fallbackID: String? = nil
  ) throws -> OpenCodeACPSession {
    guard let id = value["sessionId"]?.stringValue ?? fallbackID else {
      throw OpenCodeACPError.malformedResponse
    }
    try validateIdentifier(id)
    let options = try parseConfigOptions(value["configOptions"])
    return OpenCodeACPSession(id: id, configOptions: options)
  }

  static func parseConfigOptions(_ value: ACPJSONValue?) throws
    -> [OpenCodeACPConfigOption]
  {
    guard let value else { return [] }
    guard let rawOptions = value.arrayValue, rawOptions.count <= 64 else {
      throw OpenCodeACPError.malformedResponse
    }
    var seen = Set<String>()
    return try rawOptions.map { raw in
      guard let object = raw.objectValue,
        let id = object["id"]?.stringValue,
        seen.insert(id).inserted
      else {
        throw OpenCodeACPError.malformedResponse
      }
      try validateIdentifier(id)
      let currentValue = object["currentValue"]?.stringValue
      if let currentValue { try validateConfigText(currentValue, maximumBytes: 256) }
      let rawValues = object["options"]?.arrayValue ?? []
      guard rawValues.count <= 512 else { throw OpenCodeACPError.malformedResponse }
      var seenValues = Set<String>()
      let values = try rawValues.map { rawValue -> OpenCodeACPConfigValue in
        guard let entry = rawValue.objectValue,
          let value = entry["value"]?.stringValue,
          let name = entry["name"]?.stringValue,
          seenValues.insert(value).inserted
        else {
          throw OpenCodeACPError.malformedResponse
        }
        try validateConfigText(value, maximumBytes: 256)
        try validateConfigText(name, maximumBytes: 512)
        return OpenCodeACPConfigValue(value: value, name: name)
      }
      return OpenCodeACPConfigOption(id: id, currentValue: currentValue, values: values)
    }
  }

  private static func validateConfigText(_ value: String, maximumBytes: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximumBytes, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw OpenCodeACPError.malformedResponse
    }
  }

  static func validateIdentifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0") else {
      throw AgentRuntimeError.invalidRequest("identifier")
    }
  }

  func validateIdentifier(_ value: String) throws {
    try Self.validateIdentifier(value)
  }

  func validateAbsolutePath(_ value: String) throws {
    guard AgentPathSemantics.isAbsolute(value), value.utf8.count <= 16 * 1_024,
      !value.contains("\0")
    else {
      throw AgentRuntimeError.invalidRequest("path")
    }
  }
}
