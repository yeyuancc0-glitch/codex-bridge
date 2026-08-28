import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  public func insertProject(_ project: ServiceProjectRecord) throws {
    do {
      try database.write { db in
        if try Self.projectRow(id: project.id, in: db) != nil {
          throw ServiceStoreError.duplicateProject(project.id)
        }
        if try Self.projectRow(root: project.root, in: db) != nil {
          throw ServiceStoreError.duplicateProjectRoot(project.root.canonicalPath)
        }
        try Self.insert(project, in: db)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      if (try? database.read({ try Self.projectRow(id: project.id, in: $0) })) != nil {
        throw ServiceStoreError.duplicateProject(project.id)
      }
      if (try? database.read({ try Self.projectRow(root: project.root, in: $0) })) != nil {
        throw ServiceStoreError.duplicateProjectRoot(project.root.canonicalPath)
      }
      throw ServiceStoreError.storageFailure
    }
  }

  public func updateProject(_ project: ServiceProjectRecord) throws {
    let workspaceCommands = try encoder.encode(project.workspaceCommands)
    let commandBlacklist = try encoder.encode(project.commandBlacklist)
    guard workspaceCommands.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    guard commandBlacklist.count <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    do {
      try database.write { db in
        guard let row = try Self.projectRow(id: project.id, in: db) else {
          throw ServiceStoreError.unknownProject(project.id)
        }
        let existing = try Self.decodeProject(row)
        guard existing.root == project.root,
          existing.createdAt == project.createdAt,
          project.updatedAt >= existing.updatedAt
        else {
          throw ServiceStoreError.invalidArgument("project.update")
        }
        try db.execute(
          sql: """
            UPDATE bridge_service_projects
            SET name = ?, read_permission = ?, write_permission = ?,
                network_permission = ?, direct_command_mode = ?,
                workspace_commands_json = ?,
                direct_blacklist_json = ?, updated_at = ?
            WHERE project_id = ?
            """,
          arguments: [
            project.name,
            project.accessPolicy.read.rawValue,
            project.accessPolicy.write.rawValue,
            project.accessPolicy.network.rawValue,
            project.directCommandMode.rawValue,
            workspaceCommands,
            commandBlacklist,
            project.updatedAt.timeIntervalSince1970,
            project.id.rawValue,
          ]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func refreshLegacyProjectRoot(
    projectID: ProjectID,
    expected: ServiceRootIdentity,
    replacement: ServiceRootIdentity
  ) throws {
    guard expected.volumeUUID == nil,
      replacement.volumeUUID != nil,
      expected.canonicalPath == replacement.canonicalPath,
      expected.inode == replacement.inode
    else {
      throw ServiceStoreError.invalidArgument("project.rootRefresh")
    }
    do {
      try database.write { db in
        try db.execute(
          sql: """
            UPDATE bridge_service_projects
            SET root_device = ?, root_volume_uuid = ?
            WHERE project_id = ? AND canonical_path = ?
              AND root_device = ? AND root_inode = ? AND root_volume_uuid IS NULL
            """,
          arguments: [
            String(replacement.device),
            replacement.volumeUUID,
            projectID.rawValue,
            expected.canonicalPath,
            String(expected.device),
            String(expected.inode),
          ]
        )
        guard db.changesCount == 1 else {
          throw ServiceStoreError.invalidArgument("project.rootRefresh")
        }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func updateWorkspaceConfiguration(
    projectID: ProjectID,
    directCommandMode: ServiceDirectCommandMode?,
    workspaceCommands: [ServiceWorkspaceCommand]?,
    commandBlacklist: [ServiceCommandBlacklistRule]?,
    at date: Date
  ) throws {
    try ServiceValidation.date(date, field: "project.updatedAt")
    guard workspaceCommands?.count ?? 0 <= 128 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    guard commandBlacklist?.count ?? 0 <= 128 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    let workspaceCommandsData = try workspaceCommands.map { try encoder.encode($0) }
    let commandBlacklistData = try commandBlacklist.map { try encoder.encode($0) }
    guard workspaceCommandsData?.count ?? 0 <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.workspaceCommands")
    }
    guard commandBlacklistData?.count ?? 0 <= 262_144 else {
      throw ServiceStoreError.invalidArgument("project.commandBlacklist")
    }
    do {
      try database.write { db in
        guard let row = try Self.projectRow(id: projectID, in: db) else {
          throw ServiceStoreError.unknownProject(projectID)
        }
        let existing = try Self.decodeProject(row)
        guard date >= existing.updatedAt else {
          throw ServiceStoreError.invalidArgument("project.updatedAt")
        }
        try db.execute(
          sql: """
            UPDATE bridge_service_projects
            SET direct_command_mode = COALESCE(?, direct_command_mode),
                workspace_commands_json = COALESCE(?, workspace_commands_json),
                direct_blacklist_json = COALESCE(?, direct_blacklist_json), updated_at = ?
            WHERE project_id = ?
            """,
          arguments: [
            directCommandMode?.rawValue,
            workspaceCommandsData,
            commandBlacklistData,
            date.timeIntervalSince1970,
            projectID.rawValue,
          ]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func removeProject(id: ProjectID) throws {
    do {
      try database.write { db in
        guard try Self.projectRow(id: id, in: db) != nil else {
          throw ServiceStoreError.unknownProject(id)
        }
        let activeTaskCount =
          try Int.fetchOne(
            db,
            sql: """
              SELECT COUNT(*) FROM bridge_service_tasks
              WHERE project_id = ?
                AND status NOT IN ('completed', 'failed', 'interrupted')
              """,
            arguments: [id.rawValue]
          ) ?? 0
        guard activeTaskCount == 0 else {
          throw ServiceStoreError.invalidArgument("project.activeTasks")
        }
        try db.execute(
          sql: "DELETE FROM bridge_service_tasks WHERE project_id = ?",
          arguments: [id.rawValue]
        )
        try db.execute(
          sql: "DELETE FROM bridge_service_projects WHERE project_id = ?",
          arguments: [id.rawValue]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.unknownProject(id) }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func project(id: ProjectID) throws -> ServiceProjectRecord? {
    do {
      return try database.read { db in
        try Self.projectRow(id: id, in: db).map(Self.decodeProject)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func projects() throws -> [ServiceProjectRecord] {
    do {
      return try database.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM bridge_service_projects
            ORDER BY name COLLATE NOCASE, project_id
            """
        ).map(Self.decodeProject)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
