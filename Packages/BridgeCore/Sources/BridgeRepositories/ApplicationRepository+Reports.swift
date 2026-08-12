import BridgeDomain
import BridgeReporting
import Foundation
import GRDB

extension ApplicationRepository {
  public func storeFinalReport(
    _ document: FinalReportDocument,
    storedAt: Date = Date()
  ) throws -> FinalReportMetadata {
    let metadata = try Self.validatedMetadata(for: document, storedAt: storedAt)
    return try database.write { db in
      if let stored = try Self.fetchFinalReport(taskID: metadata.taskID, in: db) {
        guard stored.json == document.json else {
          throw ApplicationRepositoryError.finalReportConflict(metadata.taskID)
        }
        return stored.metadata
      }

      try db.execute(
        sql: """
          INSERT INTO bridge_repository_final_reports (
              task_id, schema_version, status, project_name, thread_id,
              stored_at, report_json, report_sha256
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          metadata.taskID.rawValue,
          Int(metadata.schemaVersion),
          metadata.status.rawValue,
          metadata.project,
          metadata.threadID,
          metadata.storedAt.timeIntervalSince1970,
          document.json,
          Self.digest(document.json),
        ]
      )
      return metadata
    }
  }

  public func finalReport(for taskID: TaskID) throws -> StoredFinalReport? {
    try Self.validateIdentifier(taskID.rawValue, field: "task_id", maximum: 256)
    return try database.read { db in
      try Self.fetchFinalReport(taskID: taskID, in: db)
    }
  }

  static func fetchFinalReport(
    taskID: TaskID,
    in db: Database
  ) throws -> StoredFinalReport? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT task_id, schema_version, status, project_name, thread_id,
                 stored_at, report_json, report_sha256
          FROM bridge_repository_final_reports WHERE task_id = ?
          """,
        arguments: [taskID.rawValue]
      )
    else { return nil }
    return try decodeFinalReport(row)
  }

  static func decodeFinalReport(_ row: Row) throws -> StoredFinalReport {
    let taskID = TaskID(rawValue: row["task_id"])
    let storedVersion: Int64 = row["schema_version"]
    guard let schemaVersion = UInt16(exactly: storedVersion) else {
      throw ApplicationRepositoryError.corruptRecord("final_report.schema_version")
    }
    guard schemaVersion == ReportBuilder.schemaVersion else {
      throw ApplicationRepositoryError.unsupportedSchemaVersion(storedVersion)
    }
    let statusValue: String = row["status"]
    guard let status = FinalReportStatus(rawValue: statusValue) else {
      throw ApplicationRepositoryError.corruptRecord("final_report.status")
    }
    let timestamp: Double = row["stored_at"]
    let json: Data = row["report_json"]
    let storedDigest: Data = row["report_sha256"]
    guard timestamp.isFinite, json.count <= maximumReportJSONBytes else {
      throw ApplicationRepositoryError.corruptRecord("final_report.bounds")
    }
    guard storedDigest == digest(json) else {
      throw ApplicationRepositoryError.corruptRecord("final_report.checksum")
    }
    let report = try reportMetadataObject(json)
    let project: String = row["project_name"]
    let threadID: String = row["thread_id"]
    guard report.taskID == taskID.rawValue,
      report.schemaVersion == storedVersion,
      report.status == status.rawValue,
      report.project == project,
      report.threadID == threadID
    else {
      throw ApplicationRepositoryError.corruptRecord("final_report.metadata")
    }
    try rejectSensitiveReportContent(json)
    let metadata = FinalReportMetadata(
      taskID: taskID,
      schemaVersion: schemaVersion,
      status: status,
      project: project,
      threadID: threadID,
      storedAt: Date(timeIntervalSince1970: timestamp),
      byteCount: json.count
    )
    return StoredFinalReport(metadata: metadata, json: json)
  }

  static func validatedMetadata(
    for document: FinalReportDocument,
    storedAt: Date
  ) throws -> FinalReportMetadata {
    let report = document.report
    let taskID = TaskID(rawValue: report.taskID)
    try validateIdentifier(taskID.rawValue, field: "task_id", maximum: 256)
    try validateIdentifier(report.project, field: "project", maximum: 16_384)
    try validateIdentifier(report.threadID, field: "thread_id", maximum: 1_024)
    guard report.schemaVersion == ReportBuilder.schemaVersion else {
      throw ApplicationRepositoryError.unsupportedSchemaVersion(Int64(report.schemaVersion))
    }
    guard storedAt.timeIntervalSince1970.isFinite else {
      throw ApplicationRepositoryError.invalidArgument("stored_at")
    }
    guard document.json.count <= maximumReportJSONBytes else {
      throw ApplicationRepositoryError.limitExceeded(
        field: "report_json",
        maximum: maximumReportJSONBytes
      )
    }
    guard try encodeReport(report) == document.json else {
      throw ApplicationRepositoryError.corruptRecord("final_report.document")
    }
    try rejectSensitiveReportContent(document.json)
    return FinalReportMetadata(
      taskID: taskID,
      schemaVersion: report.schemaVersion,
      status: report.status,
      project: report.project,
      threadID: report.threadID,
      storedAt: storedAt,
      byteCount: document.json.count
    )
  }

  static func encodeReport(_ report: FinalReport) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(report)
  }

  static func reportMetadataObject(_ data: Data) throws -> ReportMetadataObject {
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw ApplicationRepositoryError.corruptRecord("final_report.json")
    }
    guard let object = value as? [String: Any],
      let taskID = object["task_id"] as? String,
      let schemaNumber = object["schema_version"] as? NSNumber,
      let status = object["status"] as? String,
      let project = object["project"] as? String,
      let threadID = object["thread_id"] as? String
    else {
      throw ApplicationRepositoryError.corruptRecord("final_report.json")
    }
    return ReportMetadataObject(
      taskID: taskID,
      schemaVersion: schemaNumber.int64Value,
      status: status,
      project: project,
      threadID: threadID
    )
  }

  static func rejectSensitiveReportContent(_ data: Data) throws {
    let value = String(decoding: data, as: UTF8.self)
    let patterns = [
      #"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
      #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#,
      #"\bsk[-_][A-Za-z0-9_-]{12,}\b"#,
      #"(?i)(?:password|passwd|secret|api[_-]?key|runtime[_-]?key|access[_-]?token|refresh[_-]?token)\s*[:=]\s*[^\s,;\"]{8,}"#,
    ]
    guard !patterns.contains(where: { value.range(of: $0, options: .regularExpression) != nil })
    else {
      throw ApplicationRepositoryError.sensitiveReportContent
    }
  }
}

struct ReportMetadataObject {
  let taskID: String
  let schemaVersion: Int64
  let status: String
  let project: String
  let threadID: String
}
