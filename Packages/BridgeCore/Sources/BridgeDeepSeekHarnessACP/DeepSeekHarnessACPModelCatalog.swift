import BridgeAgentCore
import Foundation

enum DeepSeekHarnessACPModelCatalog {
  static let defaultModelID = "deepseek-v4-pro"
  static let defaultReasoningEffort = "max"
  static let supportedReasoningEfforts = ["off", "low", "high", "max"]

  private static let legacyOpenCodePrefix = "opencode-go/"
  private static let thinkingPrefix = "    thinking: "
  private static let reasoningPrefix = "    reasoningEffort: "
  private static let modelsHeader = "    models:\n"
  private static let modelEntryPrefix = "      - id: "
  private static let modelsEndAnchor = "- id: sandbox\n"
  private static let selectedModelPrefix = "    model: "
  private static let maximumModels = 256

  struct Profile: Equatable, Sendable {
    let modelIDs: [String]
    let defaultModelID: String
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [String]
  }

  static func descriptors(
    configuration: Data,
    template: Data,
    selectedModelID: String? = nil
  ) throws -> [AgentModelDescriptor] {
    let profile = try profile(configuration: configuration, template: template)
    if let selectedModelID {
      _ = try canonicalModelID(selectedModelID, profile: profile)
    }
    return try profile.modelIDs.map { modelID in
      try AgentModelDescriptor(
        id: modelID,
        displayName: modelID,
        supportedReasoningEfforts: profile.supportedReasoningEfforts,
        defaultReasoningEffort: profile.defaultReasoningEffort
      )
    }
  }

  static func resolvedSelection(
    configuration: Data,
    template: Data,
    modelID: String?,
    reasoningEffort: String?
  ) throws -> (modelID: String, reasoningEffort: String) {
    let profile = try profile(configuration: configuration, template: template)
    let resolvedModelID = try canonicalModelID(
      modelID ?? profile.defaultModelID,
      profile: profile
    )
    let resolvedEffort = reasoningEffort ?? profile.defaultReasoningEffort
    guard profile.supportedReasoningEfforts.contains(resolvedEffort) else {
      throw AgentRuntimeError.invalidRequest("request.effort")
    }
    return (resolvedModelID, resolvedEffort)
  }

  static func runtimeConfiguration(
    from configuration: Data,
    template: Data,
    modelID: String?,
    reasoningEffort: String?
  ) throws -> Data {
    let selection = try resolvedSelection(
      configuration: configuration,
      template: template,
      modelID: modelID,
      reasoningEffort: reasoningEffort
    )
    guard var value = String(data: configuration, encoding: .utf8) else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    value = try replacingScalar(
      prefix: reasoningPrefix,
      with: selection.reasoningEffort,
      in: value
    )
    value = try replacingScalar(
      prefix: selectedModelPrefix,
      with: selection.modelID,
      in: value
    )
    return Data(value.utf8)
  }

  static func profile(configuration: Data, template: Data) throws -> Profile {
    guard let value = String(data: configuration, encoding: .utf8),
      let templateValue = String(data: template, encoding: .utf8)
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    let parsed = try parsedProfile(from: value)
    _ = try parsedProfile(from: templateValue)
    guard try normalized(value) == normalized(templateValue) else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    return parsed
  }

  private static func parsedProfile(from value: String) throws -> Profile {
    let modelIDs = try modelIDs(from: value)
    let selectedModel = try scalarValue(prefix: selectedModelPrefix, in: value)
    let thinking = try scalarValue(prefix: thinkingPrefix, in: value)
    let effort = try scalarValue(prefix: reasoningPrefix, in: value)
    let efforts: [String]
    if thinking == "enabled" {
      efforts = supportedReasoningEfforts
    } else if thinking == "disabled", effort == "off" {
      efforts = ["off"]
    } else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    guard !modelIDs.isEmpty, modelIDs.count <= maximumModels,
      Set(modelIDs).count == modelIDs.count,
      modelIDs.contains(selectedModel),
      efforts.contains(effort)
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    return Profile(
      modelIDs: modelIDs,
      defaultModelID: selectedModel,
      defaultReasoningEffort: effort,
      supportedReasoningEfforts: efforts
    )
  }

  private static func modelIDs(from value: String) throws -> [String] {
    let range = try modelBlockRange(in: value)
    var lines = value[range].split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.last?.isEmpty == true else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    lines.removeLast()
    return try lines.map { line in
      guard line.hasPrefix(modelEntryPrefix) else {
        throw DeepSeekHarnessACPError.templateMismatch
      }
      let modelID = String(line.dropFirst(modelEntryPrefix.count))
      guard isValidModelID(modelID) else {
        throw DeepSeekHarnessACPError.templateMismatch
      }
      return modelID
    }
  }

  private static func normalized(_ value: String) throws -> String {
    var result = value
    let modelRange = try modelBlockRange(in: result)
    result.replaceSubrange(modelRange, with: "\(modelEntryPrefix)\(defaultModelID)\n")
    result = try replacingScalar(prefix: thinkingPrefix, with: "enabled", in: result)
    result = try replacingScalar(
      prefix: reasoningPrefix,
      with: defaultReasoningEffort,
      in: result
    )
    result = try replacingScalar(
      prefix: selectedModelPrefix,
      with: defaultModelID,
      in: result
    )
    return result
  }

  private static func canonicalModelID(_ modelID: String, profile: Profile) throws -> String {
    if profile.modelIDs.contains(modelID) { return modelID }
    if modelID.hasPrefix(legacyOpenCodePrefix) {
      let legacyWireID = String(modelID.dropFirst(legacyOpenCodePrefix.count))
      if profile.modelIDs.contains(legacyWireID) { return legacyWireID }
    }
    throw AgentRuntimeError.modelUnavailable(modelID)
  }

  private static func scalarValue(prefix: String, in value: String) throws -> String {
    let matches = value.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { $0.hasPrefix(prefix) }
    guard matches.count == 1 else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    let scalar = String(matches[0].dropFirst(prefix.count))
    guard !scalar.isEmpty else { throw DeepSeekHarnessACPError.templateMismatch }
    return scalar
  }

  private static func replacingScalar(
    prefix: String,
    with replacement: String,
    in value: String
  ) throws -> String {
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
    let matching = lines.indices.filter { lines[$0].hasPrefix(prefix) }
    guard matching.count == 1 else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    var updated = lines.map(String.init)
    updated[matching[0]] = prefix + replacement
    return updated.joined(separator: "\n")
  }

  private static func modelBlockRange(in value: String) throws -> Range<String.Index> {
    guard let header = value.range(of: modelsHeader),
      value[header.upperBound...].range(of: modelsHeader) == nil,
      let end = value[header.upperBound...].range(of: modelsEndAnchor),
      value[end.upperBound...].range(of: modelsEndAnchor) == nil
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    return header.upperBound..<end.lowerBound
  }

  private static func isValidModelID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && value.allSatisfy { character in
        character.isASCII
          && (character.isLetter || character.isNumber || "._/:-".contains(character))
      }
  }
}
