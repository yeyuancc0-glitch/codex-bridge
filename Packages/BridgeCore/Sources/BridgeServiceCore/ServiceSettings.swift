import Foundation

public enum ServiceMCPExposureMode: String, Codable, CaseIterable, Sendable {
  case readOnly = "read-only"
  case full
}

public enum ServiceSettingKey: String, CaseIterable, Sendable {
  case mcpExposureMode = "mcp.exposure_mode"
  case defaultExecutionModel = "models.execution.default"
  case defaultExecutionEffort = "models.execution.effort"
  case defaultSupervisorModel = "models.supervisor.default"
  case defaultSupervisorEffort = "models.supervisor.effort"
  case supervisorEnabled = "supervisor.enabled"
  case tunnelID = "tunnel.id"
  case tunnelEnabled = "tunnel.enabled"
}

public struct ServiceModelPreferences: Codable, Equatable, Sendable {
  public let executionModel: String
  public let executionEffort: String
  public let supervisorModel: String
  public let supervisorEffort: String

  public init(
    executionModel: String,
    executionEffort: String,
    supervisorModel: String,
    supervisorEffort: String
  ) {
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
  }
}

public actor ServiceSettings {
  private let store: SimpleServiceStore
  private let now: @Sendable () -> Date

  public init(
    store: SimpleServiceStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.now = now
  }

  public func exposureMode() async throws -> ServiceMCPExposureMode {
    guard let setting = try await store.setting(key: ServiceSettingKey.mcpExposureMode.rawValue)
    else {
      return .readOnly
    }
    guard let mode = ServiceMCPExposureMode(rawValue: setting.value) else {
      throw ServiceStoreError.corruptRecord
    }
    return mode
  }

  public func setExposureMode(_ mode: ServiceMCPExposureMode) async throws {
    try await set(mode.rawValue, for: .mcpExposureMode)
  }

  public func setModelPreferences(_ preferences: ServiceModelPreferences) async throws {
    let updatedAt = now()
    try await store.setSettings([
      try ServiceSettingRecord(
        key: ServiceSettingKey.defaultExecutionModel.rawValue,
        value: preferences.executionModel,
        updatedAt: updatedAt
      ),
      try ServiceSettingRecord(
        key: ServiceSettingKey.defaultExecutionEffort.rawValue,
        value: preferences.executionEffort,
        updatedAt: updatedAt
      ),
      try ServiceSettingRecord(
        key: ServiceSettingKey.defaultSupervisorModel.rawValue,
        value: preferences.supervisorModel,
        updatedAt: updatedAt
      ),
      try ServiceSettingRecord(
        key: ServiceSettingKey.defaultSupervisorEffort.rawValue,
        value: preferences.supervisorEffort,
        updatedAt: updatedAt
      ),
    ])
  }

  public func string(for key: ServiceSettingKey) async throws -> String? {
    guard let value = try await store.setting(key: key.rawValue)?.value, !value.isEmpty else {
      return nil
    }
    return value
  }

  public func isSupervisorEnabled() async throws -> Bool {
    guard let setting = try await store.setting(key: ServiceSettingKey.supervisorEnabled.rawValue)
    else {
      return true
    }
    guard let enabled = Bool(setting.value) else {
      throw ServiceStoreError.corruptRecord
    }
    return enabled
  }

  public func setSupervisorEnabled(_ enabled: Bool) async throws {
    try await set(String(enabled), for: .supervisorEnabled)
  }

  public func set(_ value: String?, for key: ServiceSettingKey) async throws {
    try await store.setSetting(
      ServiceSettingRecord(
        key: key.rawValue,
        value: value ?? "",
        updatedAt: now()
      )
    )
  }
}
