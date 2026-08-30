import BridgeAgentCore
import Foundation

extension AntigravityCLIProvider {
  public func models(
    installation: AgentInstallation,
    projectRoot: String?
  ) async throws -> [AgentModelDescriptor] {
    try await models(
      installation: installation,
      projectRoot: projectRoot,
      selectedModelID: nil
    )
  }

  public func models(
    installation: AgentInstallation,
    projectRoot: String?,
    selectedModelID: String?
  ) async throws -> [AgentModelDescriptor] {
    guard installation.providerID == .antigravity else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let resolved = try Self.resolvedExecutable(installation.executablePath)
    let environment = try configuration.launchBuilder.commandEnvironment(
      executablePath: resolved,
      sourceEnvironment: configuration.sourceEnvironment
    )
    let result = try await configuration.commandRunner.run(
      argv: [resolved, "models"],
      workingDirectory: projectRoot,
      environment: environment,
      timeout: configuration.requestTimeout
    )
    guard !result.timedOut else { throw AgentRuntimeError.timedOut }
    guard Self.succeeded(result.termination) else {
      throw Self.runtimeError(Self.processError(result.termination))
    }
    let models = Self.parseModels(result.standardOutput.tail)
    guard !models.isEmpty else {
      throw AgentRuntimeError.capabilityUnavailable(.modelSelection)
    }
    if let selectedModelID, !models.contains(where: { $0.id == selectedModelID }) {
      throw AgentRuntimeError.modelUnavailable(selectedModelID)
    }
    return models
  }

  static func parseModels(_ output: String) -> [AgentModelDescriptor] {
    let plain = output.replacingOccurrences(
      of: "\u{001B}\\[[0-9;]*m",
      with: "",
      options: .regularExpression
    )
    var seen = Set<String>()
    return plain.split(separator: "\n").compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { return nil }
      let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      guard let slugPart = fields.first else { return nil }
      let slug = String(slugPart)
      guard seen.insert(slug).inserted,
        slug.utf8.count <= 256,
        slug.rangeOfCharacter(from: .controlCharacters) == nil,
        !slug.contains(":")
      else { return nil }
      let displayName =
        fields.count == 2
        ? String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        : slug
      let efforts = Self.efforts(slug: slug, displayName: displayName)
      return try? AgentModelDescriptor(
        id: slug,
        displayName: displayName.isEmpty ? slug : displayName,
        supportedReasoningEfforts: efforts,
        defaultReasoningEffort: efforts.count == 1 ? efforts[0] : nil
      )
    }
  }

  static func efforts(slug: String, displayName: String) -> [String] {
    let values = ["low", "medium", "high"]
    let lowerSlug = slug.lowercased()
    if let effort = values.first(where: { lowerSlug.hasSuffix("-\($0)") }) {
      return [effort]
    }
    let lowerDisplayName = displayName.lowercased()
    if let effort = values.first(where: {
      lowerDisplayName.contains("(\($0))") || lowerDisplayName.hasSuffix(" \($0)")
    }) {
      return [effort]
    }
    return values
  }
}
