import BridgeDomain
import BridgeExecution
import BridgeProjects
import BridgeReporting
import BridgeSecurity
import CryptoKit
import Foundation
import GRDB

public actor ApplicationRepository:
  MutableProjectRepository, ProjectRootRebindingRepository, ThreadBindingRepository,
  DurableThreadBindingStore, FinalReportStore
{
  static let maximumProjectJSONBytes = 256 * 1_024
  static let maximumReportJSONBytes = 256 * 1_024
  static let maximumWorktrees = 256
  static let maximumConfigurationItems = 128

  let database: DatabaseQueue

  public init(path: String) throws {
    guard !path.isEmpty, path.utf8.count <= 16_384, !path.contains("\0") else {
      throw ApplicationRepositoryError.invalidArgument("path")
    }

    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.foreignKeysEnabled = true
    let database: DatabaseQueue
    do {
      database = try DatabaseQueue(path: path, configuration: configuration)
    } catch {
      throw ApplicationRepositoryError.databaseUnavailable
    }
    try ApplicationRepositorySchema.prepare(database)
    try Self.validateStoredRecords(in: database)
    self.database = database
  }

  public static func inMemory() throws -> ApplicationRepository {
    try ApplicationRepository(path: ":memory:")
  }

  static func validateStoredRecords(in database: DatabaseQueue) throws {
    try database.read { db in
      let projectRows = try Row.fetchAll(
        db,
        sql: """
          SELECT project_id, configuration_json, configuration_sha256
          FROM bridge_repository_projects
          """
      )
      for row in projectRows {
        let project = try decodeProject(
          row["configuration_json"],
          expectedID: row["project_id"],
          expectedDigest: row["configuration_sha256"]
        )
        try validateStoredRoots(of: project, in: db)
      }

      let bindingIDs = try String.fetchAll(
        db,
        sql: "SELECT thread_id FROM bridge_repository_thread_bindings"
      )
      for threadID in bindingIDs {
        _ = try fetchBinding(threadID: threadID, in: db)
      }

      let reportIDs = try String.fetchAll(
        db,
        sql: "SELECT task_id FROM bridge_repository_final_reports"
      )
      for rawTaskID in reportIDs {
        _ = try fetchFinalReport(taskID: TaskID(rawValue: rawTaskID), in: db)
      }
    }
  }

  static func validateIdentifier(
    _ value: String,
    field: String,
    maximum: Int
  ) throws {
    guard !value.isEmpty, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ApplicationRepositoryError.invalidArgument(field)
    }
    guard value.utf8.count <= maximum else {
      throw ApplicationRepositoryError.limitExceeded(field: field, maximum: maximum)
    }
  }

  static func digest(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }
}
