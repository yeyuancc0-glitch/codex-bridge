import Foundation
import GRDB

public actor SimpleServiceStore {
  let database: DatabaseQueue
  let encoder = JSONEncoder()

  public init(path: String) throws {
    guard !path.isEmpty else { throw ServiceStoreError.invalidArgument("path") }
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.foreignKeysEnabled = true
    do {
      let openedDatabase = try DatabaseQueue(path: path, configuration: configuration)
      try ServiceStoreSchema.createPreMigrationBackupIfNeeded(
        openedDatabase,
        sourcePath: path
      )
      try ServiceStoreSchema.prepare(openedDatabase)
      database = openedDatabase
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public static func inMemory() throws -> SimpleServiceStore {
    try SimpleServiceStore(path: ":memory:")
  }
}
