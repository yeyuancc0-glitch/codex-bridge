import BridgeDomain
import BridgeReporting
import BridgeSecurity
import Foundation

public enum ApplicationRepositoryError: Error, Equatable, Sendable {
  case invalidArgument(String)
  case limitExceeded(field: String, maximum: Int)
  case databaseUnavailable
  case corruptSchema
  case unsupportedSchemaVersion(Int64)
  case unknownMigration(String)
  case corruptRecord(String)
  case unregisteredBindingRoot
  case finalReportConflict(TaskID)
  case sensitiveReportContent
}

public struct ThreadProjectBindingRecord: Codable, Equatable, Sendable {
  public let threadID: String
  public let projectID: ProjectID
  public let root: RegisteredRoot
  public let boundAt: Date

  public init(
    threadID: String,
    projectID: ProjectID,
    root: RegisteredRoot,
    boundAt: Date
  ) {
    self.threadID = threadID
    self.projectID = projectID
    self.root = root
    self.boundAt = boundAt
  }
}

public struct FinalReportMetadata: Codable, Equatable, Sendable {
  public let taskID: TaskID
  public let schemaVersion: UInt16
  public let status: FinalReportStatus
  public let project: String
  public let threadID: String
  public let storedAt: Date
  public let byteCount: Int

  public init(
    taskID: TaskID,
    schemaVersion: UInt16,
    status: FinalReportStatus,
    project: String,
    threadID: String,
    storedAt: Date,
    byteCount: Int
  ) {
    self.taskID = taskID
    self.schemaVersion = schemaVersion
    self.status = status
    self.project = project
    self.threadID = threadID
    self.storedAt = storedAt
    self.byteCount = byteCount
  }
}

public struct StoredFinalReport: Equatable, Sendable {
  public let metadata: FinalReportMetadata
  public let json: Data

  public init(metadata: FinalReportMetadata, json: Data) {
    self.metadata = metadata
    self.json = json
  }
}

public protocol DurableThreadBindingStore: Sendable {
  func storeBinding(_ binding: ThreadProjectBindingRecord) async throws
  func storedBinding(for threadID: String) async throws -> ThreadProjectBindingRecord?
}

public protocol FinalReportStore: Sendable {
  func storeFinalReport(
    _ document: FinalReportDocument,
    storedAt: Date
  ) async throws -> FinalReportMetadata

  func finalReport(for taskID: TaskID) async throws -> StoredFinalReport?
}
