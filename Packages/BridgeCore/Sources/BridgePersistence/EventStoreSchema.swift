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
    migrator.registerMigration("addDurableTaskChangeLog") { db in
      try db.execute(
        sql: """
          CREATE TABLE task_change_log (
              change_id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id TEXT NOT NULL,
              event_seq INTEGER NOT NULL CHECK (event_seq > 0),
              kind TEXT NOT NULL,
              created_at REAL NOT NULL,
              UNIQUE (task_id, event_seq),
              FOREIGN KEY (task_id, event_seq)
                REFERENCES task_events(task_id, seq) ON DELETE RESTRICT
          )
          """)
      try db.execute(
        sql: """
          CREATE INDEX task_change_log_task_event
          ON task_change_log(task_id, event_seq)
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER task_events_insert_change_log
          AFTER INSERT ON task_events
          BEGIN
            INSERT INTO task_change_log (task_id, event_seq, kind, created_at)
            VALUES (NEW.task_id, NEW.seq, NEW.kind, NEW.created_at);
          END
          """)
    }
    migrator.registerMigration("addTaskNotificationLedger") { db in
      try db.execute(
        sql: """
          CREATE TABLE task_notification_consumers (
              consumer_id TEXT PRIMARY KEY NOT NULL,
              change_cursor INTEGER NOT NULL CHECK (change_cursor >= 0),
              updated_at REAL NOT NULL
          )
          """)
      try db.execute(
        sql: """
          CREATE TABLE task_notification_ledger (
              consumer_id TEXT NOT NULL,
              stable_key TEXT NOT NULL,
              change_id INTEGER NOT NULL,
              task_id TEXT NOT NULL,
              event_seq INTEGER NOT NULL CHECK (event_seq > 0),
              kind TEXT NOT NULL,
              state TEXT NOT NULL CHECK (state IN ('reserved', 'scheduled')),
              reserved_at REAL NOT NULL,
              scheduled_at REAL,
              PRIMARY KEY (consumer_id, stable_key),
              UNIQUE (consumer_id, change_id),
              FOREIGN KEY (consumer_id)
                REFERENCES task_notification_consumers(consumer_id) ON DELETE RESTRICT,
              FOREIGN KEY (change_id)
                REFERENCES task_change_log(change_id) ON DELETE RESTRICT,
              FOREIGN KEY (task_id, event_seq)
                REFERENCES task_events(task_id, seq) ON DELETE RESTRICT
          )
          """)
      try db.execute(
        sql: """
          CREATE INDEX task_notification_ledger_pending
          ON task_notification_ledger(consumer_id, state, change_id)
          """)
    }
    migrator.registerMigration("addTaskNotificationLeases") { db in
      try db.execute(
        sql: """
          ALTER TABLE task_notification_ledger
          ADD COLUMN owner_instance_id TEXT NOT NULL DEFAULT 'unclaimed'
          """)
      try db.execute(
        sql: """
          ALTER TABLE task_notification_ledger
          ADD COLUMN lease_until REAL NOT NULL DEFAULT 0
          """)
      try db.execute(
        sql: """
          CREATE INDEX task_notification_ledger_claimable
          ON task_notification_ledger(consumer_id, state, lease_until, change_id)
          """)
    }
    migrator.registerMigration("addLifecyclePreferences") { db in
      try db.execute(
        sql: """
          CREATE TABLE lifecycle_preferences (
              singleton_id INTEGER PRIMARY KEY NOT NULL CHECK (singleton_id = 1),
              notifications_enabled INTEGER NOT NULL
                CHECK (notifications_enabled IN (0, 1)),
              idle_sleep_enabled INTEGER NOT NULL
                CHECK (idle_sleep_enabled IN (0, 1)),
              updated_at REAL NOT NULL
          )
          """)
      try db.execute(
        sql: """
          INSERT INTO lifecycle_preferences (
              singleton_id, notifications_enabled, idle_sleep_enabled, updated_at
          ) VALUES (1, 0, 1, 0)
          """)
    }
    migrator.registerMigration("addTaskChangeHeadState") { db in
      try db.execute(
        sql: """
          CREATE TABLE task_change_state (
              singleton_id INTEGER PRIMARY KEY NOT NULL CHECK (singleton_id = 1),
              head_change_id INTEGER NOT NULL CHECK (head_change_id >= 0)
          )
          """)
      try db.execute(
        sql: """
          INSERT INTO task_change_state (singleton_id, head_change_id)
          VALUES (1, COALESCE((SELECT MAX(change_id) FROM task_change_log), 0))
          """)
      try db.execute(sql: "DROP TRIGGER task_events_insert_change_log")
      try db.execute(
        sql: """
          CREATE TRIGGER task_events_insert_change_log
          AFTER INSERT ON task_events
          BEGIN
            INSERT INTO task_change_log (task_id, event_seq, kind, created_at)
            VALUES (NEW.task_id, NEW.seq, NEW.kind, NEW.created_at);
            UPDATE task_change_state
            SET head_change_id = last_insert_rowid()
            WHERE singleton_id = 1;
          END
          """)
    }
    try migrator.migrate(database)
  }
}
