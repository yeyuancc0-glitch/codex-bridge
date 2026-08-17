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

  public func string(for key: ServiceSettingKey) async throws -> String? {
    guard let value = try await store.setting(key: key.rawValue)?.value, !value.isEmpty else {
      return nil
    }
    return value
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
