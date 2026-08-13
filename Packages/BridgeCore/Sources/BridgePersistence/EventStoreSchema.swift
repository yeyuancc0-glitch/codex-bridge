import GRDB

enum EventStoreSchema {
  static func migrate(_ database: DatabaseQueue) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("createEventStore") { db in
      try db.execute(
        sql: """
          CREATE TABLE tasks (
              task_id TEXT PRIMARY KEY NOT NULL,
              last_event_seq INTEGER NOT NULL DEFAULT 0 CHECK (last_event_seq >= 0),
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
          )
          """)
      try db.execute(
        sql: """
          CREATE TABLE task_events (
              task_id TEXT NOT NULL,
              seq INTEGER NOT NULL CHECK (seq > 0),
              schema_version INTEGER NOT NULL CHECK (schema_version BETWEEN 0 AND 65535),
              source TEXT NOT NULL,
              kind TEXT NOT NULL,
              severity TEXT NOT NULL,
              payload BLOB NOT NULL,
              created_at REAL NOT NULL,
              PRIMARY KEY (task_id, seq),
              FOREIGN KEY (task_id) REFERENCES tasks(task_id) ON DELETE RESTRICT
          )
          """)
      try db.execute(
        sql: """
          CREATE TABLE submission_claims (
              origin TEXT NOT NULL,
              idempotency_key TEXT NOT NULL,
              request_fingerprint TEXT NOT NULL,
              task_id TEXT NOT NULL,
              created_at REAL NOT NULL,
              PRIMARY KEY (origin, idempotency_key),
              FOREIGN KEY (task_id) REFERENCES tasks(task_id) ON DELETE RESTRICT
          )
          """)
      try db.execute(
        sql: """
          CREATE INDEX submission_claims_task_id
          ON submission_claims(task_id)
          """)
      try db.execute(
        sql: """
          CREATE TABLE locks (
              lock_key TEXT PRIMARY KEY NOT NULL,
              owner_task_id TEXT NOT NULL,
              acquired_at REAL NOT NULL,
              FOREIGN KEY (owner_task_id) REFERENCES tasks(task_id) ON DELETE RESTRICT
          )
          """)
    }
    migrator.registerMigration("addTaskStateSnapshots") { db in
      try db.execute(
        sql: """
          CREATE TABLE task_state_snapshots (
              task_id TEXT PRIMARY KEY NOT NULL,
              last_event_seq INTEGER NOT NULL CHECK (last_event_seq > 0),
              schema_version INTEGER NOT NULL CHECK (schema_version BETWEEN 0 AND 65535),
              payload BLOB NOT NULL,
              recovery_required INTEGER NOT NULL CHECK (recovery_required IN (0, 1)),
              FOREIGN KEY (task_id) REFERENCES tasks(task_id) ON DELETE RESTRICT
          )
          """)
      try db.execute(
        sql: """
          CREATE INDEX task_state_snapshots_recovery
          ON task_state_snapshots(recovery_required, task_id)
          """)
    }
    try migrator.migrate(database)
  }
}
