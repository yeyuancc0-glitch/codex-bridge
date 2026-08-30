import BridgeAgentCore
import CryptoKit
import Foundation

public struct DeepSeekHarnessACPProfile: Sendable {
  public let configurationTemplate: Data

  public init(configurationTemplate: Data? = nil) throws {
    if let configurationTemplate {
      guard !configurationTemplate.isEmpty,
        configurationTemplate.count <= DeepSeekHarnessACPConstants.maximumFinalTextBytes
      else {
        throw DeepSeekHarnessACPError.templateMismatch
      }
      self.configurationTemplate = configurationTemplate
    } else {
      self.configurationTemplate = try Self.bundledConfigurationTemplate()
    }
  }

  public static func bundledConfigurationTemplate() throws -> Data {
    guard let url = Bundle.module.url(forResource: "cordis", withExtension: "yml"),
      let data = try? Data(contentsOf: url),
      !data.isEmpty
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    return data
  }

  public var configurationTemplateDigest: String {
    SHA256.hash(data: configurationTemplate).map { String(format: "%02x", $0) }.joined()
  }

  public static func resolveArtifacts(
    executablePath: String,
    configurationPath: String,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> [AgentInstallationArtifactRole: String] {
    let profile = try Self.init()
    return try DeepSeekHarnessACPArtifactValidator.resolveArtifacts(
      executablePath: executablePath,
      configurationPath: configurationPath,
      configurationTemplate: profile.configurationTemplate,
      sourceEnvironment: sourceEnvironment
    )
  }

  public func validate(_ installation: AgentInstallation) throws
    -> DeepSeekHarnessACPValidatedInstallation
  {
    try DeepSeekHarnessACPArtifactValidator.validate(
      installation,
      configurationTemplate: configurationTemplate
    )
  }

  func modelDescriptors(
    for installation: AgentInstallation,
    selectedModelID: String?
  ) throws -> [AgentModelDescriptor] {
    let configuration = try validatedConfigurationData(for: installation)
    return try DeepSeekHarnessACPModelCatalog.descriptors(
      configuration: configuration,
      template: configurationTemplate,
      selectedModelID: selectedModelID
    )
  }

  func resolvedSelection(
    for installation: AgentInstallation,
    modelID: String?,
    reasoningEffort: String?
  ) throws -> (modelID: String, reasoningEffort: String) {
    let configuration = try validatedConfigurationData(for: installation)
    return try DeepSeekHarnessACPModelCatalog.resolvedSelection(
      configuration: configuration,
      template: configurationTemplate,
      modelID: modelID,
      reasoningEffort: reasoningEffort
    )
  }

  public static func isCompatibleNodeVersion(_ version: String) -> Bool {
    DeepSeekHarnessACPArtifactRuntime.isCompatibleNodeVersion(version)
  }

  private func validatedConfigurationData(for installation: AgentInstallation) throws -> Data {
    try DeepSeekHarnessACPArtifactValidator.validatedConfigurationData(
      for: installation,
      configurationTemplate: configurationTemplate
    )
  }
}
