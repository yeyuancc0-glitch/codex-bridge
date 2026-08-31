import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceCustomInstructions(
    deadline: ContinuousClock.Instant
  ) async throws -> String {
    try Self.checkDeadline(deadline)
    return try await settings.customInstructions()
  }

  public func setServiceCustomInstructions(
    _ instructions: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setCustomInstructions(instructions)
  }

  public func serviceModels(
    deadline: ContinuousClock.Instant
  ) async throws -> MCPModelList {
    try await catalog.listModels(deadline: deadline)
  }

  public func serviceModelPreferences(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceModelPreferences {
    try await serviceModelCatalog(deadline: deadline).preferences
  }

  public func serviceModelCatalog(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceModelCatalog {
    try Self.checkDeadline(deadline)
    let models = try await catalog.listModels(deadline: deadline)
    let preferences = try await resolvedDefaultModelPreferences(models: models.models)
    return ServiceModelCatalog(models: models, preferences: preferences)
  }

  public func setServiceModelPreferences(
    _ preferences: ServiceModelPreferences,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    let models = try await catalog.listModels(deadline: deadline).models
    _ = try Self.select(
      modelID: preferences.executionModel,
      effort: preferences.executionEffort,
      models: models
    )
    _ = try Self.select(
      modelID: preferences.supervisorModel,
      effort: preferences.supervisorEffort,
      models: models
    )
    try Self.checkDeadline(deadline)
    try await settings.setModelPreferences(preferences)
  }

  public func setSupervisorEnabled(_ enabled: Bool) async throws {
    #if os(Windows)
      guard !enabled else { throw BridgeMCPQueryError.contractRejected }
    #endif
    try await settings.setSupervisorEnabled(enabled)
  }
}
