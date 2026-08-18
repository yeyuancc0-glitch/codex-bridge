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
  case executionAccessMode = "execution.access_mode"
  case executionFastMode = "execution.fast_mode"
  case tunnelID = "tunnel.id"
  case tunnelEnabled = "tunnel.enabled"
}

public struct ServiceModelPreferences: Codable, Equatable, Sendable {
  public let executionModel: String
  public let executionEffort: String
  public let supervisorModel: String
  public let supervisorEffort: String
  public let accessMode: ServiceAccessMode
  public let fastModeEnabled: Bool

  public init(
    executionModel: String,
    executionEffort: String,
    supervisorModel: String,
    supervisorEffort: String,
    accessMode: ServiceAccessMode = .requestApproval,
    fastModeEnabled: Bool = false
  ) {
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.accessMode = accessMode
    self.fastModeEnabled = fastModeEnabled
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
      try ServiceSettingRecord(
        key: ServiceSettingKey.executionAccessMode.rawValue,
        value: preferences.accessMode.rawValue,
        updatedAt: updatedAt
      ),
      try ServiceSettingRecord(
        key: ServiceSettingKey.executionFastMode.rawValue,
        value: String(preferences.fastModeEnabled),
        updatedAt: updatedAt
      ),
    ])
  }

  public func accessMode() async throws -> ServiceAccessMode {
    guard let setting = try await store.setting(key: ServiceSettingKey.executionAccessMode.rawValue)
    else {
      return .requestApproval
    }
    guard let mode = ServiceAccessMode(rawValue: setting.value) else {
      throw ServiceStoreError.corruptRecord
    }
    return mode
  }

  public func isFastModeEnabled() async throws -> Bool {
    guard let setting = try await store.setting(key: ServiceSettingKey.executionFastMode.rawValue)
    else {
      return false
    }
    guard let enabled = Bool(setting.value) else {
      throw ServiceStoreError.corruptRecord
    }
    return enabled
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
