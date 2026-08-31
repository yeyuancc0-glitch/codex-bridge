import GRDB

extension ServiceStoreSchema {
  private static let v15Tables = [
    "bridge_service_projects",
    "bridge_service_tasks",
    "bridge_service_task_events",
    "bridge_service_task_messages",
    "bridge_service_agent_installations",
    "bridge_service_agent_installation_artifacts",
  ]

  private static let v15DropOrder = [
    "bridge_service_task_messages",
    "bridge_service_task_events",
    "bridge_service_tasks",
    "bridge_service_agent_installation_artifacts",
    "bridge_service_agent_installations",
    "bridge_service_projects",
  ]

  private static let v15CreateOrder = [
    "bridge_service_projects",
    "bridge_service_tasks",
    "bridge_service_task_events",
    "bridge_service_task_messages",
    "bridge_service_agent_installations",
    "bridge_service_agent_installation_artifacts",
  ]

  static func createVersionFifteen(in db: Database) throws {
    let definitions = try tableDefinitions(in: db)
    let indexes = try indexDefinitions(in: db)
    let counts = try rowCounts(in: db)
    try snapshotTables(in: db)
    for table in v15DropOrder {
      try db.execute(sql: "DROP TABLE \(table)")
    }
    for table in v15CreateOrder {
      guard let definition = definitions[table] else { throw ServiceStoreError.corruptSchema }
      try db.execute(sql: try portableDefinition(definition, for: table))
      try db.execute(
        sql: "INSERT INTO \(table) SELECT * FROM \(snapshotName(for: table))"
      )
    }
    for index in indexes {
      try db.execute(sql: index)
    }
    for table in v15Tables {
      try db.execute(sql: "DROP TABLE \(snapshotName(for: table))")
      guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == counts[table] else {
        throw ServiceStoreError.corruptSchema
      }
    }
    guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
      throw ServiceStoreError.corruptSchema
    }
    try db.execute(
      sql: "UPDATE bridge_service_meta SET schema_version = 15 WHERE singleton = 1"
    )
  }

  private static func tableDefinitions(in db: Database) throws -> [String: String] {
    var definitions: [String: String] = [:]
    for table in v15Tables {
      guard
        let definition = try String.fetchOne(
          db,
          sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
          arguments: [table]
        )
      else {
        throw ServiceStoreError.corruptSchema
      }
      definitions[table] = definition
    }
    return definitions
  }

  private static func indexDefinitions(in db: Database) throws -> [String] {
    var definitions: [String] = []
    for table in v15Tables {
      definitions.append(
        contentsOf: try String.fetchAll(
          db,
          sql: """
            SELECT sql FROM sqlite_master
            WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL
            ORDER BY name
            """,
          arguments: [table]
        )
      )
    }
    return definitions
  }

  private static func rowCounts(in db: Database) throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for table in v15Tables {
      guard let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") else {
        throw ServiceStoreError.corruptSchema
      }
      counts[table] = count
    }
    return counts
  }

  private static func snapshotTables(in db: Database) throws {
    for table in v15Tables {
      try db.execute(
        sql: "CREATE TEMP TABLE \(snapshotName(for: table)) AS SELECT * FROM \(table)"
      )
    }
  }

  private static func portableDefinition(_ definition: String, for table: String) throws -> String {
    guard
      table == "bridge_service_projects"
        || table == "bridge_service_agent_installations"
        || table == "bridge_service_agent_installation_artifacts"
    else {
      return definition
    }
    switch table {
    case "bridge_service_projects", "bridge_service_agent_installation_artifacts":
      return try replacingPathCheck(in: definition, column: "canonical_path")
    case "bridge_service_agent_installations":
      let withExecutable = try replacingPathCheck(in: definition, column: "executable_path")
      return try replacingPathCheck(
        in: withExecutable,
        column: "canonical_executable_path"
      )
    default:
      throw ServiceStoreError.corruptSchema
    }
  }

  private static func replacingPathCheck(in definition: String, column: String) throws -> String {
    let legacyCheck = "CHECK (substr(\(column), 1, 1) = '/'),"
    let occurrences = definition.components(separatedBy: legacyCheck).count - 1
    guard occurrences == 1 else { throw ServiceStoreError.corruptSchema }
    return definition.replacingOccurrences(
      of: legacyCheck,
      with: """
        CHECK (
          substr(\(column), 1, 1) = '/'
          OR (
            substr(\(column), 1, 1) GLOB '[A-Za-z]'
            AND substr(\(column), 2, 1) = ':'
            AND (
              substr(\(column), 3, 1) = '/'
              OR substr(\(column), 3, 1) = char(92)
            )
          )
          OR (
            (
              substr(\(column), 1, 1) = '/'
              OR substr(\(column), 1, 1) = char(92)
            )
            AND (
              substr(\(column), 2, 1) = '/'
              OR substr(\(column), 2, 1) = char(92)
            )
          )
        ),
        """
    )
  }

  private static func snapshotName(for table: String) -> String {
    table.replacingOccurrences(of: "bridge_service_", with: "bridge_service_v15_data_")
  }
}
