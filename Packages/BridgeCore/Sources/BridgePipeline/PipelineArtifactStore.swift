import BridgeDomain
import CryptoKit
import Foundation
import GRDB

public actor PipelineArtifactStore {
  public static let maximumPayloadBytes = 512 * 1_024
  static let maximumActiveScopes = 128
  static let maximumActiveArtifacts = 512
  static let maximumArtifactsPerActiveScope = 64
  static let maximumActivePayloadBytes = 32 * 1_024 * 1_024
  static let activeScopeQuery = """
    SELECT s.* FROM bridge_pipeline_scopes s
    JOIN bridge_pipeline_current_scopes c
      ON c.task_id = s.task_id AND c.generation = s.generation
    WHERE s.stage IN (
      'created', 'baseline_captured', 'turn_completed', 'git_final_captured',
      'verification_completed', 'supervisor_reviewed', 'report_stored'
    )
    LIMIT ?
    """
  static let activeArtifactQuery = """
    SELECT kind_category, kind_key, schema_version, payload_json,
           payload_sha256, created_at
    FROM bridge_pipeline_artifacts
    WHERE task_id = ? AND generation = ?
    ORDER BY kind_category ASC, kind_key ASC
    LIMIT ?
    """
  private let database: DatabaseQueue

  public init(path: String) throws {
    guard !path.isEmpty, path.utf8.count <= 16_384, !path.contains("\0") else {
      throw PipelineArtifactStoreError.invalidArgument("path")
    }
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.foreignKeysEnabled = true
    do {
      database = try DatabaseQueue(path: path, configuration: configuration)
    } catch {
      throw PipelineArtifactStoreError.databaseUnavailable
    }
    try PipelineArtifactSchema.prepare(database)
    try Self.validateActiveRecords(in: database)
  }

  public static func inMemory() throws -> PipelineArtifactStore {
    try PipelineArtifactStore(path: ":memory:")
  }

  @discardableResult
  public func begin(_ scope: TaskEvidenceScope, at date: Date = Date()) throws
    -> PipelineFinalizationRecord
  {
    try Self.validate(date: date, field: "date")
    return try database.write { db in
      if let current = try Self.fetchCurrentScope(taskID: scope.taskID, in: db) {
        return try Self.beginReplacing(current, with: scope, at: date, in: db)
      }
      try Self.insertScope(scope, at: date, in: db)
      try Self.setCurrent(scope, in: db)
      return PipelineFinalizationRecord(
        scope: scope,
        stage: .created,
        createdAt: date,
        updatedAt: date
      )
    }
  }

  @discardableResult
  public func store<Payload: Encodable & Sendable>(
    scope: TaskEvidenceScope,
    kind: PipelineArtifactKind,
    schemaVersion: UInt16 = 1,
    payload: Payload,
    at date: Date = Date()
  ) throws -> PipelineArtifactRecord {
    guard schemaVersion > 0 else {
      throw PipelineArtifactStoreError.invalidArgument("schemaVersion")
    }
    try Self.validate(date: date, field: "date")
    let validatedKind = try kind.validated()
    let json = try Self.canonicalJSON(payload)
    guard json.count <= Self.maximumPayloadBytes else {
      throw PipelineArtifactStoreError.limitExceeded(
        field: "payload",
        maximum: Self.maximumPayloadBytes
      )
    }
    let digest = Self.digest(json)
    return try database.write { db in
      _ = try Self.requireCurrentScope(scope, in: db)
      if let stored = try Self.fetchArtifact(scope: scope, kind: validatedKind, in: db) {
        guard stored.payload == json, stored.digest == digest,
          stored.record.schemaVersion == schemaVersion
        else {
          throw PipelineArtifactStoreError.artifactConflict(scope.taskID, validatedKind)
        }
        return stored.record
      }
      try db.execute(
        sql: """
          INSERT INTO bridge_pipeline_artifacts (
            task_id, generation, kind_category, kind_key, schema_version,
            payload_json, payload_sha256, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          scope.taskID.rawValue, scope.generation, validatedKind.category, validatedKind.key,
          Int(schemaVersion), json, digest, date.timeIntervalSince1970,
        ]
      )
      return Self.makeArtifactRecord(
        scope: scope,
        kind: validatedKind,
        schemaVersion: schemaVersion,
        payload: json,
        digest: digest,
        createdAt: date
      )
    }
  }

  @discardableResult
  public func advance(
    _ scope: TaskEvidenceScope,
    to stage: PipelineStage,
    at date: Date = Date()
  ) throws -> PipelineFinalizationRecord {
    try Self.validate(date: date, field: "date")
    return try database.write { db in
      let current = try Self.requireCurrentScope(scope, in: db)
      guard current.stage != stage else { return current }
      try Self.validateTransition(from: current.stage, to: stage, scope: scope, in: db)
      try db.execute(
        sql: """
          UPDATE bridge_pipeline_scopes SET stage = ?, updated_at = ?
          WHERE task_id = ? AND generation = ? AND stage = ?
          """,
        arguments: [
          stage.rawValue, date.timeIntervalSince1970, scope.taskID.rawValue,
          scope.generation, current.stage.rawValue,
        ]
      )
      guard db.changesCount == 1 else {
        throw PipelineArtifactStoreError.scopeConflict(scope.taskID)
      }
      return PipelineFinalizationRecord(
        scope: scope,
        stage: stage,
        createdAt: current.createdAt,
        updatedAt: date
      )
    }
  }

  public func currentScope(for taskID: TaskID) throws -> TaskEvidenceScope? {
    try database.read { db in
      try Self.fetchCurrentScope(taskID: taskID, in: db)?.scope
    }
  }

  public func finalization(for taskID: TaskID) throws -> PipelineFinalizationRecord? {
    try database.read { db in
      try Self.fetchCurrentScope(taskID: taskID, in: db)
    }
  }

  public func pendingFinalizations(limit: Int = 100) throws -> [PipelineFinalizationRecord] {
    guard (1...1_000).contains(limit) else {
      throw PipelineArtifactStoreError.invalidArgument("limit")
    }
    return try database.read { db in
      let stages = PipelineStage.allCases.filter(\.isPendingFinalization).map(\.rawValue)
      let placeholders = Array(repeating: "?", count: stages.count).joined(separator: ",")
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT s.* FROM bridge_pipeline_scopes s
          JOIN bridge_pipeline_current_scopes c
            ON c.task_id = s.task_id AND c.generation = s.generation
          WHERE s.stage IN (\(placeholders))
          ORDER BY s.updated_at ASC, s.task_id ASC
          LIMIT ?
          """,
        arguments: StatementArguments(stages) + [limit]
      )
      return try rows.map(Self.decodeFinalization)
    }
  }

  public func recoverableFinalizations(limit: Int = 128) throws
    -> [PipelineFinalizationRecord]
  {
    guard (1...Self.maximumActiveScopes).contains(limit) else {
      throw PipelineArtifactStoreError.invalidArgument("limit")
    }
    return try database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT s.* FROM bridge_pipeline_scopes s
          JOIN bridge_pipeline_current_scopes c
            ON c.task_id = s.task_id AND c.generation = s.generation
          WHERE s.stage IN ('supervisor_reviewed', 'report_stored')
            AND EXISTS (
              SELECT 1 FROM bridge_pipeline_artifacts a
              WHERE a.task_id = s.task_id AND a.generation = s.generation
                AND a.kind_category = 'report_metadata' AND a.kind_key = ''
            )
          ORDER BY s.updated_at ASC, s.task_id ASC
          LIMIT ?
          """,
        arguments: [limit]
      )
      return try rows.map(Self.decodeFinalization)
    }
  }

  public func artifacts(for scope: TaskEvidenceScope) throws -> [PipelineArtifactRecord] {
    try database.read { db in
      try Self.requireScope(scope, in: db)
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT kind_category, kind_key, schema_version, payload_json,
                 payload_sha256, created_at
          FROM bridge_pipeline_artifacts
          WHERE task_id = ? AND generation = ?
          ORDER BY kind_category ASC, kind_key ASC
          """,
        arguments: [scope.taskID.rawValue, scope.generation]
      )
      return try rows.map { try Self.decodeArtifact($0, scope: scope).record }
    }
  }

  public func trustedPayload<Payload: Decodable & Sendable>(
    for scope: TaskEvidenceScope,
    kind: PipelineArtifactKind,
    as type: Payload.Type = Payload.self
  ) throws -> Payload? {
    let validatedKind = try kind.validated()
    return try database.read { db in
      try Self.requireScope(scope, in: db)
      guard let artifact = try Self.fetchArtifact(scope: scope, kind: validatedKind, in: db)
      else { return nil }
      do {
        return try JSONDecoder().decode(type, from: artifact.payload)
      } catch {
        throw PipelineArtifactStoreError.corruptRecord
      }
    }
  }

  private static func beginReplacing(
    _ current: PipelineFinalizationRecord,
    with scope: TaskEvidenceScope,
    at date: Date,
    in db: Database
  ) throws -> PipelineFinalizationRecord {
    if current.scope == scope { return current }
    guard current.stage.isTerminal, scope.generation > current.scope.generation,
      scope.eventSequence > current.scope.eventSequence
    else {
      throw PipelineArtifactStoreError.scopeConflict(scope.taskID)
    }
    try insertScope(scope, at: date, in: db)
    try setCurrent(scope, in: db)
    return PipelineFinalizationRecord(
      scope: scope,
      stage: .created,
      createdAt: date,
      updatedAt: date
    )
  }

  private static func insertScope(_ scope: TaskEvidenceScope, at date: Date, in db: Database)
    throws
  {
    try db.execute(
      sql: """
        INSERT INTO bridge_pipeline_scopes (
          task_id, generation, project_id, thread_id, turn_id, event_sequence,
          stage, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 'created', ?, ?)
        """,
      arguments: [
        scope.taskID.rawValue, scope.generation, scope.projectID.rawValue,
        scope.threadID.rawValue, scope.turnID.rawValue, scope.eventSequence,
        date.timeIntervalSince1970, date.timeIntervalSince1970,
      ]
    )
  }

  private static func setCurrent(_ scope: TaskEvidenceScope, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_pipeline_current_scopes (task_id, generation) VALUES (?, ?)
        ON CONFLICT(task_id) DO UPDATE SET generation = excluded.generation
        """,
      arguments: [scope.taskID.rawValue, scope.generation]
    )
  }

  private static func validateTransition(
    from current: PipelineStage,
    to target: PipelineStage,
    scope: TaskEvidenceScope,
    in db: Database
  ) throws {
    if target == .failed || target == .superseded {
      guard !current.isTerminal else {
        throw PipelineArtifactStoreError.invalidStageTransition(from: current, to: target)
      }
      return
    }
    guard current.next == target else {
      throw PipelineArtifactStoreError.invalidStageTransition(from: current, to: target)
    }
    if target == .verificationCompleted {
      try requireVerification(scope: scope, in: db)
    }
    if let prerequisite = prerequisite(for: target) {
      try requireArtifact(prerequisite, scope: scope, in: db)
    }
  }

  private static func prerequisite(for stage: PipelineStage) -> PipelineArtifactKind? {
    switch stage {
    case .baselineCaptured: .gitBaseline
    case .gitFinalCaptured: .gitFinal
    case .supervisorReviewed: .supervisorFinalDecision
    case .reportStored, .completed: .reportMetadata
    default: nil
    }
  }

  private static func requireArtifact(
    _ kind: PipelineArtifactKind,
    scope: TaskEvidenceScope,
    in db: Database
  ) throws {
    guard try fetchArtifact(scope: scope, kind: kind, in: db) != nil else {
      throw PipelineArtifactStoreError.missingPrerequisite(kind)
    }
  }

  private static func requireVerification(scope: TaskEvidenceScope, in db: Database) throws {
    let count =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bridge_pipeline_artifacts
          WHERE task_id = ? AND generation = ? AND kind_category = 'verification'
          """,
        arguments: [scope.taskID.rawValue, scope.generation]
      ) ?? 0
    guard count > 0 else {
      throw PipelineArtifactStoreError.missingPrerequisite(.verification("required"))
    }
  }

  private static func requireScope(_ scope: TaskEvidenceScope, in db: Database) throws {
    guard
      let stored = try fetchScope(taskID: scope.taskID, generation: scope.generation, in: db),
      stored.scope == scope
    else { throw PipelineArtifactStoreError.scopeConflict(scope.taskID) }
  }

  private static func requireCurrentScope(_ scope: TaskEvidenceScope, in db: Database) throws
    -> PipelineFinalizationRecord
  {
    guard let current = try fetchCurrentScope(taskID: scope.taskID, in: db),
      current.scope == scope
    else { throw PipelineArtifactStoreError.scopeConflict(scope.taskID) }
    return current
  }

  private static func fetchCurrentScope(taskID: TaskID, in db: Database) throws
    -> PipelineFinalizationRecord?
  {
    guard
      let generation = try Int64.fetchOne(
        db,
        sql: "SELECT generation FROM bridge_pipeline_current_scopes WHERE task_id = ?",
        arguments: [taskID.rawValue]
      )
    else { return nil }
    guard let scope = try fetchScope(taskID: taskID, generation: generation, in: db) else {
      throw PipelineArtifactStoreError.corruptRecord
    }
    return scope
  }

  private static func fetchScope(taskID: TaskID, generation: Int64, in db: Database) throws
    -> PipelineFinalizationRecord?
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM bridge_pipeline_scopes WHERE task_id = ? AND generation = ?",
        arguments: [taskID.rawValue, generation]
      )
    else { return nil }
    return try decodeFinalization(row)
  }

  private struct StoredArtifact {
    let record: PipelineArtifactRecord
    let payload: Data
    let digest: Data
  }

  private static func fetchArtifact(
    scope: TaskEvidenceScope,
    kind: PipelineArtifactKind,
    in db: Database
  ) throws -> StoredArtifact? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT kind_category, kind_key, schema_version, payload_json,
                 payload_sha256, created_at
          FROM bridge_pipeline_artifacts
          WHERE task_id = ? AND generation = ? AND kind_category = ? AND kind_key = ?
          """,
        arguments: [scope.taskID.rawValue, scope.generation, kind.category, kind.key]
      )
    else { return nil }
    return try decodeArtifact(row, scope: scope)
  }

  private static func decodeFinalization(_ row: Row) throws -> PipelineFinalizationRecord {
    guard let stage = PipelineStage(rawValue: row["stage"]) else {
      throw PipelineArtifactStoreError.corruptRecord
    }
    let scope = try TaskEvidenceScope(
      taskID: TaskID(rawValue: row["task_id"]),
      projectID: ProjectID(rawValue: row["project_id"]),
      threadID: ThreadID(rawValue: row["thread_id"]),
      turnID: TurnID(rawValue: row["turn_id"]),
      generation: row["generation"],
      eventSequence: row["event_sequence"]
    )
    let createdAt: Double = row["created_at"]
    let updatedAt: Double = row["updated_at"]
    guard createdAt.isFinite, updatedAt.isFinite else {
      throw PipelineArtifactStoreError.corruptRecord
    }
    return PipelineFinalizationRecord(
      scope: scope,
      stage: stage,
      createdAt: Date(timeIntervalSince1970: createdAt),
      updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
  }

  private static func decodeArtifact(_ row: Row, scope: TaskEvidenceScope) throws
    -> StoredArtifact
  {
    let kind = try PipelineArtifactKind.decode(
      category: row["kind_category"],
      key: row["kind_key"]
    )
    let version: Int = row["schema_version"]
    guard let schemaVersion = UInt16(exactly: version), schemaVersion > 0 else {
      throw PipelineArtifactStoreError.corruptRecord
    }
    let payload: Data = row["payload_json"]
    let digest: Data = row["payload_sha256"]
    guard payload.count <= maximumPayloadBytes, digest.count == 32,
      Self.digest(payload) == digest,
      (try? canonicalize(payload)) == payload
    else { throw PipelineArtifactStoreError.corruptRecord }
    let timestamp: Double = row["created_at"]
    guard timestamp.isFinite else { throw PipelineArtifactStoreError.corruptRecord }
    let createdAt = Date(timeIntervalSince1970: timestamp)
    return StoredArtifact(
      record: makeArtifactRecord(
        scope: scope,
        kind: kind,
        schemaVersion: schemaVersion,
        payload: payload,
        digest: digest,
        createdAt: createdAt
      ),
      payload: payload,
      digest: digest
    )
  }

  private static func makeArtifactRecord(
    scope: TaskEvidenceScope,
    kind: PipelineArtifactKind,
    schemaVersion: UInt16,
    payload: Data,
    digest: Data,
    createdAt: Date
  ) -> PipelineArtifactRecord {
    PipelineArtifactRecord(
      scope: scope,
      kind: kind,
      schemaVersion: schemaVersion,
      payloadByteCount: payload.count,
      sha256: digest.map { String(format: "%02x", $0) }.joined(),
      createdAt: createdAt
    )
  }

  private static func canonicalJSON<Payload: Encodable>(_ payload: Payload) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return try canonicalize(encoder.encode(payload))
    } catch let error as PipelineArtifactStoreError {
      throw error
    } catch {
      throw PipelineArtifactStoreError.invalidArgument("payload")
    }
  }

  private static func canonicalize(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    guard JSONSerialization.isValidJSONObject(object) else {
      throw PipelineArtifactStoreError.invalidArgument("payload")
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  private static func digest(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  private static func validate(date: Date, field: String) throws {
    guard date.timeIntervalSince1970.isFinite else {
      throw PipelineArtifactStoreError.invalidArgument(field)
    }
  }

  private static func validateActiveRecords(in database: DatabaseQueue) throws {
    do {
      try database.read { db in
        let scopes = try Row.fetchAll(
          db,
          sql: activeScopeQuery,
          arguments: [maximumActiveScopes + 1]
        )
        guard scopes.count <= maximumActiveScopes else {
          throw PipelineArtifactStoreError.limitExceeded(
            field: "activeScopes",
            maximum: maximumActiveScopes
          )
        }
        var activeScopes: [TaskID: TaskEvidenceScope] = [:]
        for row in scopes {
          let finalization = try decodeFinalization(row)
          activeScopes[finalization.scope.taskID] = finalization.scope
        }
        var artifactCount = 0
        var payloadByteCount: Int64 = 0
        for scope in activeScopes.values {
          let rows = try Row.fetchAll(
            db,
            sql: activeArtifactQuery,
            arguments: [
              scope.taskID.rawValue, scope.generation, maximumArtifactsPerActiveScope + 1,
            ]
          )
          guard rows.count <= maximumArtifactsPerActiveScope else {
            throw PipelineArtifactStoreError.limitExceeded(
              field: "activeArtifactsPerScope",
              maximum: maximumArtifactsPerActiveScope
            )
          }
          artifactCount += rows.count
          guard artifactCount <= maximumActiveArtifacts else {
            throw PipelineArtifactStoreError.limitExceeded(
              field: "activeArtifacts",
              maximum: maximumActiveArtifacts
            )
          }
          for row in rows {
            let payload: Data = row["payload_json"]
            payloadByteCount += Int64(payload.count)
            guard payloadByteCount <= Int64(maximumActivePayloadBytes) else {
              throw PipelineArtifactStoreError.limitExceeded(
                field: "activePayloadBytes",
                maximum: maximumActivePayloadBytes
              )
            }
            _ = try decodeArtifact(row, scope: scope)
          }
        }
      }
    } catch let error as PipelineArtifactStoreError {
      throw error
    } catch {
      throw PipelineArtifactStoreError.corruptRecord
    }
  }
}
