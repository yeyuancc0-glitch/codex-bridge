import Foundation
import GRDB

public struct LifecyclePreferences: Equatable, Sendable {
  public static let defaults = LifecyclePreferences(
    notificationsEnabled: false,
    idleSleepEnabled: true,
    receivingPaused: false
  )

  public let notificationsEnabled: Bool
  public let idleSleepEnabled: Bool
  public let receivingPaused: Bool

  public init(
    notificationsEnabled: Bool,
    idleSleepEnabled: Bool,
    receivingPaused: Bool = false
  ) {
    self.notificationsEnabled = notificationsEnabled
    self.idleSleepEnabled = idleSleepEnabled
    self.receivingPaused = receivingPaused
  }
}

extension EventStore {
  public func lifecyclePreferences() throws -> LifecyclePreferences {
    try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT notifications_enabled, idle_sleep_enabled, receiving_paused
            FROM lifecycle_preferences
            WHERE singleton_id = 1
            """
        )
      else { throw EventStoreError.invalidArgument("lifecyclePreferences") }
      return try Self.decodeLifecyclePreferences(row)
    }
  }

  public func setNotificationsEnabled(_ enabled: Bool, updatedAt: Date = Date()) throws {
    guard updatedAt.timeIntervalSince1970.isFinite else {
      throw EventStoreError.invalidArgument("updatedAt")
    }
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE lifecycle_preferences
          SET notifications_enabled = ?, updated_at = ?
          WHERE singleton_id = 1
          """,
        arguments: [
          enabled,
          updatedAt.timeIntervalSince1970,
        ]
      )
      try Self.requireLifecyclePreferencesUpdate(db)
    }
  }

  public func setIdleSleepEnabled(_ enabled: Bool, updatedAt: Date = Date()) throws {
    guard updatedAt.timeIntervalSince1970.isFinite else {
      throw EventStoreError.invalidArgument("updatedAt")
    }
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE lifecycle_preferences
          SET idle_sleep_enabled = ?, updated_at = ?
          WHERE singleton_id = 1
          """,
        arguments: [
          enabled,
          updatedAt.timeIntervalSince1970,
        ]
      )
      try Self.requireLifecyclePreferencesUpdate(db)
    }
  }

  public func setReceivingPaused(_ paused: Bool, updatedAt: Date = Date()) throws {
    guard updatedAt.timeIntervalSince1970.isFinite else {
      throw EventStoreError.invalidArgument("updatedAt")
    }
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE lifecycle_preferences
          SET receiving_paused = ?, updated_at = ?
          WHERE singleton_id = 1
          """,
        arguments: [
          paused,
          updatedAt.timeIntervalSince1970,
        ]
      )
      try Self.requireLifecyclePreferencesUpdate(db)
    }
  }

  private static func decodeLifecyclePreferences(_ row: Row) throws -> LifecyclePreferences {
    let notifications: Int64 = row["notifications_enabled"]
    let idleSleep: Int64 = row["idle_sleep_enabled"]
    let receivingPaused: Int64 = row["receiving_paused"]
    guard (0...1).contains(notifications), (0...1).contains(idleSleep),
      (0...1).contains(receivingPaused)
    else {
      throw EventStoreError.invalidArgument("lifecyclePreferences")
    }
    return LifecyclePreferences(
      notificationsEnabled: notifications == 1,
      idleSleepEnabled: idleSleep == 1,
      receivingPaused: receivingPaused == 1
    )
  }

  private static func requireLifecyclePreferencesUpdate(_ db: Database) throws {
    guard db.changesCount == 1 else {
      throw EventStoreError.invalidArgument("lifecyclePreferences")
    }
  }
}
