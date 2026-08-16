import GRDB

enum EventStoreSchema {
  static let migrationIdentifiers = [
    "createEventStore",
    "addTaskStateSnapshots",
    "addDurableTaskChangeLog",
    "addTaskNotificationLedger",
    "addTaskNotificationLeases",
    "addLifecyclePreferences",
    "addTaskChangeHeadState",
    "addTaskRetentionFoundation",
  ]

  static func migrate(_ database: DatabaseQueue) throws {
    let migrator = makeMigrator()
    try DatabaseMigrationBackup.createIfNeeded(
      database: database,
      knownMigrationIdentifiers: migrationIdentifiers,
      componentIdentifier: "BridgePersistence"
    )
    try migrator.migrate(database)
  }

  static func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(migrationIdentifiers[0]) { db in
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
    migrator.registerMigration(migrationIdentifiers[1]) { db in
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
    migrator.registerMigration(migrationIdentifiers[2]) { db in
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
    migrator.registerMigration(migrationIdentifiers[3]) { db in
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
    migrator.registerMigration(migrationIdentifiers[4]) { db in
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
    migrator.registerMigration(migrationIdentifiers[5]) { db in
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
    migrator.registerMigration(migrationIdentifiers[6]) { db in
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
    migrator.registerMigration(migrationIdentifiers[7]) { db in
      try db.execute(
        sql: """
          CREATE TABLE task_retention_policy (
              singleton_id INTEGER PRIMARY KEY NOT NULL CHECK (singleton_id = 1),
              revision INTEGER NOT NULL CHECK (revision > 0),
              event_days INTEGER NOT NULL CHECK (event_days BETWEEN 1 AND 3650),
              metadata_days INTEGER NOT NULL
                CHECK (metadata_days BETWEEN event_days AND 3650),
              recent_task_limit INTEGER
                CHECK (recent_task_limit IS NULL OR recent_task_limit BETWEEN 1 AND 10000),
              updated_at REAL NOT NULL CHECK (typeof(updated_at) IN ('integer', 'real'))
          );

          INSERT INTO task_retention_policy (
              singleton_id, revision, event_days, metadata_days, recent_task_limit, updated_at
          ) VALUES (1, 1, 30, 90, NULL, 0);

          CREATE TABLE task_retained_metadata (
              task_id TEXT PRIMARY KEY NOT NULL,
              terminal_phase TEXT NOT NULL CHECK (terminal_phase IN (
                'completed', 'failed', 'interrupted', 'rejected'
              )),
              created_at REAL NOT NULL CHECK (typeof(created_at) IN ('integer', 'real')),
              started_at REAL CHECK (
                started_at IS NULL OR typeof(started_at) IN ('integer', 'real')
              ),
              completed_at REAL NOT NULL CHECK (typeof(completed_at) IN ('integer', 'real')),
              last_event_seq INTEGER NOT NULL CHECK (last_event_seq > 0),
              projection_schema_version INTEGER NOT NULL
                CHECK (projection_schema_version BETWEEN 1 AND 65535),
              projection_payload BLOB NOT NULL CHECK (
                typeof(projection_payload) = 'blob'
                AND length(projection_payload) BETWEEN 1 AND 262144
              ),
              projection_sha256 BLOB NOT NULL CHECK (
                typeof(projection_sha256) = 'blob' AND length(projection_sha256) = 32
              ),
              history_state TEXT NOT NULL CHECK (history_state IN (
                'full', 'archive_authoritative', 'payloads_pruned'
              )),
              payloads_pruned_at REAL CHECK (
                payloads_pruned_at IS NULL
                OR typeof(payloads_pruned_at) IN ('integer', 'real')
              ),
              indexed_at REAL NOT NULL CHECK (typeof(indexed_at) IN ('integer', 'real')),
              FOREIGN KEY (task_id) REFERENCES tasks(task_id) ON DELETE RESTRICT,
              CHECK (created_at <= completed_at),
              CHECK (started_at IS NULL OR (started_at >= created_at AND started_at <= completed_at)),
              CHECK (
                (history_state = 'payloads_pruned' AND payloads_pruned_at IS NOT NULL)
                OR (history_state != 'payloads_pruned' AND payloads_pruned_at IS NULL)
              )
          );

          CREATE INDEX task_retention_terminal_order
          ON task_retained_metadata(completed_at DESC, task_id DESC);

          CREATE INDEX task_events_task_kind_created
          ON task_events(task_id, kind, created_at);

          CREATE TABLE task_retention_jobs (
              task_id TEXT PRIMARY KEY NOT NULL,
              target_tier TEXT NOT NULL CHECK (target_tier IN ('payloads', 'all')),
              expected_last_event_seq INTEGER NOT NULL CHECK (expected_last_event_seq > 0),
              expected_projection_sha256 BLOB NOT NULL CHECK (
                typeof(expected_projection_sha256) = 'blob'
                AND length(expected_projection_sha256) = 32
              ),
              policy_revision INTEGER NOT NULL CHECK (policy_revision > 0),
              state TEXT NOT NULL CHECK (state IN (
                'prepared', 'pipeline_pruning', 'pipeline_pruned',
                'supervision_pruning', 'supervision_pruned', 'archive_authoritative',
                'event_history_pruning', 'event_history_pruned',
                'external_payloads_pruning', 'payloads_complete',
                'metadata_pruning', 'metadata_pruned', 'complete'
              )),
              event_cursor INTEGER NOT NULL DEFAULT 0 CHECK (event_cursor >= 0),
              pipeline_cursor INTEGER NOT NULL DEFAULT 0 CHECK (pipeline_cursor >= 0),
              supervision_cursor INTEGER NOT NULL DEFAULT 0 CHECK (supervision_cursor >= 0),
              attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
              lease_owner TEXT,
              lease_until REAL NOT NULL DEFAULT 0
                CHECK (typeof(lease_until) IN ('integer', 'real')),
              next_attempt_at REAL NOT NULL DEFAULT 0
                CHECK (typeof(next_attempt_at) IN ('integer', 'real')),
              last_error_code TEXT,
              planned_at REAL NOT NULL CHECK (typeof(planned_at) IN ('integer', 'real')),
              updated_at REAL NOT NULL CHECK (typeof(updated_at) IN ('integer', 'real')),
              CHECK (lease_owner IS NULL OR length(CAST(lease_owner AS BLOB)) BETWEEN 1 AND 128),
              CHECK (
                last_error_code IS NULL
                OR length(CAST(last_error_code AS BLOB)) BETWEEN 1 AND 128
              )
          );

          CREATE INDEX task_retention_runnable
          ON task_retention_jobs(state, next_attempt_at, lease_until, updated_at, task_id);

          CREATE TRIGGER task_events_no_update
          BEFORE UPDATE ON task_events
          BEGIN SELECT RAISE(ABORT, 'task events are append-only'); END;
          """)
    }
    return migrator
  }
}
