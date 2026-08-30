import GRDB

extension SimpleServiceStore {
  public func setSetting(_ setting: ServiceSettingRecord) throws {
    try setSettings([setting])
  }

  func setSettings(_ settings: [ServiceSettingRecord]) throws {
    do {
      try database.write { db in
        for setting in settings {
          try db.execute(
            sql: """
              INSERT INTO bridge_service_settings (setting_key, setting_value, updated_at)
              VALUES (?, ?, ?)
              ON CONFLICT(setting_key) DO UPDATE SET
                setting_value = excluded.setting_value,
                updated_at = excluded.updated_at
              """,
            arguments: [setting.key, setting.value, setting.updatedAt.timeIntervalSince1970]
          )
        }
      }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func setting(key: String) throws -> ServiceSettingRecord? {
    try ServiceValidation.identifier(key, field: "setting.key", maximumBytes: 128)
    do {
      return try database.read { db in
        try Row.fetchOne(
          db,
          sql: "SELECT * FROM bridge_service_settings WHERE setting_key = ?",
          arguments: [key]
        ).map(Self.decodeSetting)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
