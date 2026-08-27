import BridgeAgentCore
import Foundation

enum DeepSeekHarnessACPModelCatalog {
  static let modelIDPrefix = "opencode-go/"
  static let defaultModelID = "opencode-go/deepseek-v4-pro"
  static let defaultWireModelID = "deepseek-v4-pro"
  static let defaultReasoningEffort = "max"
  static let supportedReasoningEfforts = ["off", "low", "high", "max"]

  static func descriptors() throws -> [AgentModelDescriptor] {
    try [
      descriptor(id: defaultModelID, displayName: defaultModelID)
    ]
  }

  static func resolvedSelection(
    modelID: String?,
    reasoningEffort: String?
  ) throws -> (modelID: String, reasoningEffort: String) {
    let resolvedModelID = modelID ?? defaultModelID
    let wireModelID = try wireModelID(for: resolvedModelID)
    let resolvedEffort = reasoningEffort ?? defaultReasoningEffort
    guard supportedReasoningEfforts.contains(resolvedEffort) else {
      throw AgentRuntimeError.invalidRequest("request.effort")
    }
    return (wireModelID, resolvedEffort)
  }

  static func runtimeConfiguration(
    from template: Data,
    modelID: String?,
    reasoningEffort: String?
  ) throws -> Data {
    let selection = try resolvedSelection(
      modelID: modelID,
      reasoningEffort: reasoningEffort
    )
    guard var configuration = String(data: template, encoding: .utf8) else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    configuration = try replacingExactlyOnce(
      "    reasoningEffort: max",
      with: "    reasoningEffort: \(selection.reasoningEffort)",
      in: configuration
    )
    configuration = try replacingExactlyOnce(
      "      - id: deepseek-v4-pro",
      with: "      - id: \(selection.modelID)",
      in: configuration
    )
    configuration = try replacingExactlyOnce(
      "    model: deepseek-v4-pro",
      with: "    model: \(selection.modelID)",
      in: configuration
    )
    return Data(configuration.utf8)
  }

  private static func descriptor(id: String, displayName: String) throws
    -> AgentModelDescriptor
  {
    try AgentModelDescriptor(
      id: id,
      displayName: displayName,
      supportedReasoningEfforts: ["high", "max"],
      defaultReasoningEffort: defaultReasoningEffort
    )
  }

  private static func wireModelID(for modelID: String) throws -> String {
    let value: Substring
    if modelID == defaultWireModelID {
      value = Substring(modelID)
    } else if modelID.hasPrefix(modelIDPrefix) {
      value = modelID.dropFirst(modelIDPrefix.count)
    } else {
      throw AgentRuntimeError.modelUnavailable(modelID)
    }
    guard !value.isEmpty, value.utf8.count <= 256,
      value.allSatisfy({ character in
        character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
      })
    else {
      throw AgentRuntimeError.modelUnavailable(modelID)
    }
    return String(value)
  }

  private static func replacingExactlyOnce(
    _ target: String,
    with replacement: String,
    in value: String
  ) throws -> String {
    guard let range = value.range(of: target),
      value[range.upperBound...].range(of: target) == nil
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    return value.replacingCharacters(in: range, with: replacement)
  }
}
