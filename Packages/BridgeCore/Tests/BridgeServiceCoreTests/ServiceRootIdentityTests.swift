import BridgeDomain
import Foundation
import GRDB
import XCTest

@testable import BridgeServiceCore

final class ServiceRootIdentityTests: XCTestCase {
  func testVolumeUUIDMakesDeviceDriftValid() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-root-identity-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let current = try ServiceRootIdentity(capturing: directory)
    guard let volumeUUID = current.volumeUUID else {
      throw XCTSkip("The test volume does not expose a persistent UUID.")
    }
    let afterRemount = try ServiceRootIdentity(
      canonicalPath: current.canonicalPath,
      device: current.device == UInt64.max ? 0 : current.device + 1,
      inode: current.inode,
      volumeUUID: volumeUUID
    )

    XCTAssertNoThrow(try afterRemount.validateCurrentIdentity())
  }

  func testVolumeUUIDAndInodeChangesAreRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-root-identity-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let current = try ServiceRootIdentity(capturing: directory)
    guard let volumeUUID = current.volumeUUID else {
      throw XCTSkip("The test volume does not expose a persistent UUID.")
    }
    let wrongVolume = try ServiceRootIdentity(
      canonicalPath: current.canonicalPath,
      device: current.device,
      inode: current.inode,
      volumeUUID: volumeUUID + "-different"
    )
    let wrongInode = try ServiceRootIdentity(
      canonicalPath: current.canonicalPath,
      device: current.device,
      inode: current.inode == UInt64.max ? 0 : current.inode + 1,
      volumeUUID: volumeUUID
    )

    XCTAssertThrowsError(try wrongVolume.validateCurrentIdentity())
    XCTAssertThrowsError(try wrongInode.validateCurrentIdentity())
  }

  func testLegacyIdentityWithoutVolumeUUIDUsesDeviceFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-root-identity-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let current = try ServiceRootIdentity(capturing: directory)
    let legacy = try ServiceRootIdentity(
      canonicalPath: current.canonicalPath,
      device: current.device,
      inode: current.inode
    )
    let driftedDevice = try ServiceRootIdentity(
      canonicalPath: current.canonicalPath,
      device: current.device == UInt64.max ? 0 : current.device + 1,
      inode: current.inode
    )

    XCTAssertNoThrow(try legacy.validateCurrentIdentity())
    XCTAssertThrowsError(try driftedDevice.validateCurrentIdentity())
  }

  func testVersionEightMigrationCapturesVolumeUUIDAndRefreshesDevice() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-root-identity-migration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let projectRoot = directory.appending(path: "project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    let current = try ServiceRootIdentity(capturing: projectRoot)
    guard let volumeUUID = current.volumeUUID else {
      throw XCTSkip("The test volume does not expose a persistent UUID.")
    }
    let path = directory.appending(path: "service.sqlite").path
    let legacy = try DatabaseQueue(path: path)

    try await legacy.writeWithoutTransaction { db in
      try db.execute(
        sql: """
          CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
          INSERT INTO grdb_migrations (identifier)
          VALUES ('BridgeServiceCore.v1'), ('BridgeServiceCore.v2'),
                 ('BridgeServiceCore.v3'), ('BridgeServiceCore.v4'),
                 ('BridgeServiceCore.v5'), ('BridgeServiceCore.v6'),
                 ('BridgeServiceCore.v7'), ('BridgeServiceCore.v8');
          """
      )
      try ServiceStoreSchema.createVersionOne(in: db)
      try ServiceStoreSchema.createVersionTwo(in: db)
      try ServiceStoreSchema.createVersionThree(in: db)
      try ServiceStoreSchema.createVersionFour(in: db)
      try ServiceStoreSchema.createVersionFive(in: db)
      try ServiceStoreSchema.createVersionSix(in: db)
      try ServiceStoreSchema.createVersionSeven(in: db)
      try ServiceStoreSchema.createVersionEight(in: db)
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json, direct_blacklist_json,
            created_at, updated_at
          ) VALUES ('prj-volume-migration', 'Volume migration', ?, ?, ?,
            'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
            CAST('[]' AS BLOB), 1, 2)
          """,
        arguments: [
          current.canonicalPath,
          String(current.device == UInt64.max ? 0 : current.device + 1),
          String(current.inode),
        ]
      )
    }

    let store = try SimpleServiceStore(path: path)
    let project = try await store.project(id: ProjectID(rawValue: "prj-volume-migration"))
    XCTAssertEqual(project?.root.canonicalPath, current.canonicalPath)
    XCTAssertEqual(project?.root.inode, current.inode)
    XCTAssertEqual(project?.root.device, current.device)
    XCTAssertEqual(project?.root.volumeUUID, volumeUUID)

    let schema = try await store.database.read { db in
      let version = try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
      let row = try Row.fetchOne(
        db,
        sql:
          "SELECT root_device, root_inode, root_volume_uuid FROM bridge_service_projects WHERE project_id = ?",
        arguments: ["prj-volume-migration"]
      )
      return (
        version,
        row?["root_device"] as String?,
        row?["root_inode"] as String?,
        row?["root_volume_uuid"] as String?
      )
    }
    XCTAssertEqual(schema.0, 12)
    XCTAssertEqual(schema.1, String(current.device))
    XCTAssertEqual(schema.2, String(current.inode))
    XCTAssertEqual(schema.3, volumeUUID)

    let backupPath = path + ".pre-v9"
    var metadata = stat()
    XCTAssertEqual(lstat(backupPath, &metadata), 0)
    XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    let backup = try DatabaseQueue(path: backupPath)
    let backupVersion = try await backup.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
    }
    XCTAssertEqual(backupVersion, 8)
  }

  func testProjectServiceLazilyRepairsLegacyIdentityAfterOfflineMigration() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-root-identity-lazy-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let current = try ServiceRootIdentity(capturing: directory)
    let volumeUUID = try XCTUnwrap(current.volumeUUID)
    let legacyRoot = try ServiceRootIdentity(
      canonicalPath: current.canonicalPath,
      device: current.device == UInt64.max ? 0 : current.device + 1,
      inode: current.inode
    )
    let store = try SimpleServiceStore.inMemory()
    let projectID = ProjectID(rawValue: "prj-lazy-root-repair")
    let date = Date()
    try await store.insertProject(
      ServiceProjectRecord(
        id: projectID,
        name: "Lazy repair",
        root: legacyRoot,
        accessPolicy: .init(),
        createdAt: date,
        updatedAt: date
      )
    )
    let projects = ServiceProjectService(store: store)

    let repaired = try await projects.project(id: projectID)

    XCTAssertEqual(repaired?.root.device, current.device)
    XCTAssertEqual(repaired?.root.inode, current.inode)
    XCTAssertEqual(repaired?.root.volumeUUID, volumeUUID)
    XCTAssertNoThrow(try repaired?.root.validateCurrentIdentity())
  }
}
