import BridgeDomain
import BridgeProjects
import Foundation
import GRDB
import XCTest

@testable import BridgeLegacyImport
@testable import BridgeServiceCore

final class LegacyConfigurationImporterTests: XCTestCase {
  func testImportsProjectAndTunnelIDOnceWithoutChangingLegacyFiles() async throws {
    let fixture = try LegacyImportFixture(testCase: self)
    let project = try fixture.project(
      id: "legacy-project",
      policy: ProjectAccessPolicy(
        read: .allowed,
        write: .requiresLocalApproval,
        network: .denied
      )
    )
    try fixture.writeRepository(projects: [project])
    let tunnelID = "tunnel_" + String(repeating: "a", count: 32)
    try fixture.writeOnboarding(tunnelID: tunnelID)
    let repositoryDigest = try fixture.digest(of: fixture.repositoryURL)
    let onboardingDigest = try fixture.digest(of: fixture.onboardingURL)
    let importDate = Date(timeIntervalSince1970: 1_900_000_000)
    let store = try fixture.store()
    let importer = LegacyConfigurationImporter(
      legacyRootURL: fixture.legacyRoot,
      store: store,
      now: { importDate }
    )

    let report = try await importer.importIfNeeded()
    let importedRecord = try await store.project(id: project.id)
    let imported = try XCTUnwrap(importedRecord)
    let importedTunnelID = try await store.setting(
      key: ServiceSettingKey.tunnelID.rawValue
    )?.value
    let importedTunnelEnabled = try await store.setting(
      key: ServiceSettingKey.tunnelEnabled.rawValue
    )?.value
    let importedExecutionModel = try await store.setting(
      key: ServiceSettingKey.defaultExecutionModel.rawValue
    )
    let markerExists = try await store.hasConfigurationImportMarker(
      LegacyConfigurationImporter.markerKey
    )

    XCTAssertEqual(report.status, .imported)
    XCTAssertTrue(report.sourceFound)
    XCTAssertEqual(report.insertedProjectIDs, [project.id])
    XCTAssertTrue(report.reducedProjects.isEmpty)
    XCTAssertEqual(imported.name, project.name)
    XCTAssertEqual(imported.root.canonicalPath, project.primaryRoot.canonicalPath)
    XCTAssertEqual(imported.accessPolicy, project.accessPolicy)
    XCTAssertEqual(imported.createdAt, project.createdAt)
    XCTAssertEqual(imported.updatedAt, importDate)
    XCTAssertEqual(importedTunnelID, tunnelID)
    XCTAssertEqual(importedTunnelEnabled, "0")
    XCTAssertNil(importedExecutionModel)
    XCTAssertTrue(markerExists)
    XCTAssertEqual(try fixture.digest(of: fixture.repositoryURL), repositoryDigest)
    XCTAssertEqual(try fixture.digest(of: fixture.onboardingURL), onboardingDigest)

    let repeated = try await importer.importIfNeeded()
    let projectCount = try await store.projects().count
    XCTAssertEqual(repeated.status, .alreadyCompleted)
    XCTAssertEqual(projectCount, 1)
  }

  func testImportsOfflineAndComplexProjectsUsingOnlyTheirPrimaryRoots() async throws {
    let fixture = try LegacyImportFixture(testCase: self)
    let validRoot = try fixture.createDirectory("valid")
    let worktreeRoot = try fixture.createDirectory("worktree")
    let multiRoot = try fixture.createDirectory("multi")
    let repositoryRoot = try fixture.createDirectory("repository")
    let nestedRoot = try fixture.createDirectory("repository/nested")
    let offlineRoot = try fixture.createDirectory("offline")
    let valid = try fixture.project(id: "valid", rootURL: validRoot)
    let withWorktree = try fixture.project(
      id: "worktree-project",
      rootURL: multiRoot,
      worktreeURLs: [worktreeRoot]
    )
    let differentRepository = try fixture.project(
      id: "repository-project",
      rootURL: nestedRoot,
      repositoryRootURL: repositoryRoot
    )
    let offline = try fixture.project(id: "offline-project", rootURL: offlineRoot)
    try fixture.writeRepository(
      projects: [valid, withWorktree, differentRepository, offline]
    )
    try FileManager.default.removeItem(at: offlineRoot)
    let store = try fixture.store()

    let report = try await LegacyConfigurationImporter(
      legacyRootURL: fixture.legacyRoot,
      store: store
    ).importIfNeeded()
    let storedProjectIDs = Set(try await store.projects().map(\.id))
    let importedOfflineRecord = try await store.project(id: offline.id)
    let importedOffline = try XCTUnwrap(importedOfflineRecord)

    XCTAssertEqual(
      Set(report.insertedProjectIDs),
      Set([valid.id, withWorktree.id, differentRepository.id, offline.id])
    )
    XCTAssertEqual(
      Set(report.reducedProjects),
      Set([
        LegacyProjectReduction(
          projectID: withWorktree.id,
          omittedWorktreeCount: 1,
          repositoryRootWasDifferent: false
        ),
        LegacyProjectReduction(
          projectID: differentRepository.id,
          omittedWorktreeCount: 0,
          repositoryRootWasDifferent: true
        ),
      ])
    )
    XCTAssertEqual(
      storedProjectIDs,
      Set([valid.id, withWorktree.id, differentRepository.id, offline.id])
    )
    XCTAssertEqual(importedOffline.root.canonicalPath, offline.primaryRoot.canonicalPath)
    XCTAssertEqual(importedOffline.root.device, offline.primaryRoot.identity.device)
    XCTAssertEqual(importedOffline.root.inode, offline.primaryRoot.identity.inode)
  }

  func testExistingNewProjectAndTunnelSettingAreNeverOverwritten() async throws {
    let fixture = try LegacyImportFixture(testCase: self)
    let legacy = try fixture.project(id: "shared-project", name: "Legacy Name")
    try fixture.writeRepository(projects: [legacy])
    let legacyTunnelID = "tunnel_" + String(repeating: "b", count: 32)
    try fixture.writeOnboarding(tunnelID: legacyTunnelID)
    let store = try fixture.store()
    let existingDate = Date(timeIntervalSince1970: 1_950_000_000)
    let existing = try ServiceProjectRecord(
      id: legacy.id,
      name: "New Service Name",
      root: ServiceRootIdentity(
        canonicalPath: legacy.primaryRoot.canonicalPath,
        device: legacy.primaryRoot.identity.device,
        inode: legacy.primaryRoot.identity.inode
      ),
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .allowed,
        network: .requiresLocalApproval
      ),
      createdAt: existingDate,
      updatedAt: existingDate
    )
    try await store.insertProject(existing)
    let newTunnelID = "tunnel_" + String(repeating: "c", count: 32)
    try await store.setSetting(
      ServiceSettingRecord(
        key: ServiceSettingKey.tunnelID.rawValue,
        value: newTunnelID,
        updatedAt: existingDate
      )
    )

    let report = try await LegacyConfigurationImporter(
      legacyRootURL: fixture.legacyRoot,
      store: store
    ).importIfNeeded()
    let storedProject = try await store.project(id: legacy.id)
    let storedTunnelID = try await store.setting(
      key: ServiceSettingKey.tunnelID.rawValue
    )?.value
    let storedTunnelEnabled = try await store.setting(
      key: ServiceSettingKey.tunnelEnabled.rawValue
    )?.value

    XCTAssertEqual(report.existingProjectIDs, [legacy.id])
    XCTAssertEqual(report.existingSettingKeys, [ServiceSettingKey.tunnelID.rawValue])
    XCTAssertEqual(storedProject, existing)
    XCTAssertEqual(storedTunnelID, newTunnelID)
    XCTAssertEqual(storedTunnelEnabled, "0")
  }

  func testProjectConflictRollsBackSettingsAndMarker() async throws {
    let fixture = try LegacyImportFixture(testCase: self)
    let legacy = try fixture.project(id: "conflicting-project")
    try fixture.writeRepository(projects: [legacy])
    try fixture.writeOnboarding(
      tunnelID: "tunnel_" + String(repeating: "d", count: 32)
    )
    let conflictRoot = try fixture.createDirectory("conflict")
    let store = try fixture.store()
    let date = Date(timeIntervalSince1970: 1_950_000_000)
    try await store.insertProject(
      ServiceProjectRecord(
        id: legacy.id,
        name: "Conflicting New Project",
        root: ServiceRootIdentity(capturing: conflictRoot),
        accessPolicy: .init(),
        createdAt: date,
        updatedAt: date
      )
    )

    do {
      _ = try await LegacyConfigurationImporter(
        legacyRootURL: fixture.legacyRoot,
        store: store
      ).importIfNeeded()
      XCTFail("Expected the conflicting project to abort the import")
    } catch {
      XCTAssertEqual(error as? ServiceStoreError, .duplicateProject(legacy.id))
    }
    let storedTunnelID = try await store.setting(
      key: ServiceSettingKey.tunnelID.rawValue
    )
    let markerExists = try await store.hasConfigurationImportMarker(
      LegacyConfigurationImporter.markerKey
    )
    let projectCount = try await store.projects().count
    XCTAssertNil(storedTunnelID)
    XCTAssertFalse(markerExists)
    XCTAssertEqual(projectCount, 1)
  }

  func testCorruptLegacyRepositoryLeavesNewStoreAndMarkerUntouched() async throws {
    let fixture = try LegacyImportFixture(testCase: self)
    let project = try fixture.project(id: "corrupt-project")
    try fixture.writeRepository(
      projects: [project],
      corruptDigestFor: project.id
    )
    let store = try fixture.store()

    do {
      _ = try await LegacyConfigurationImporter(
        legacyRootURL: fixture.legacyRoot,
        store: store
      ).importIfNeeded()
      XCTFail("Expected the corrupt legacy database to fail closed")
    } catch {
      XCTAssertEqual(error as? LegacyImportError, .corruptRepository)
    }
    let projects = try await store.projects()
    let markerExists = try await store.hasConfigurationImportMarker(
      LegacyConfigurationImporter.markerKey
    )
    XCTAssertTrue(projects.isEmpty)
    XCTAssertFalse(markerExists)
  }

  func testMissingOrEmptyLegacySourceDoesNotWritePermanentMarker() async throws {
    let fixture = try LegacyImportFixture(testCase: self)
    try FileManager.default.removeItem(at: fixture.legacyRoot)
    let store = try fixture.store()
    let importer = LegacyConfigurationImporter(
      legacyRootURL: fixture.legacyRoot,
      store: store
    )

    let missing = try await importer.importIfNeeded()
    let markerAfterMissing = try await store.hasConfigurationImportMarker(
      LegacyConfigurationImporter.markerKey
    )
    XCTAssertEqual(missing.status, .noSource)
    XCTAssertFalse(markerAfterMissing)

    try FileManager.default.createDirectory(
      at: fixture.legacyRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let empty = try await importer.importIfNeeded()
    let markerAfterEmpty = try await store.hasConfigurationImportMarker(
      LegacyConfigurationImporter.markerKey
    )
    XCTAssertEqual(empty.status, .noSource)
    XCTAssertFalse(markerAfterEmpty)
  }

  func testInsecureLegacyFileIsRejectedWithoutACompletionMarker() async throws {
    let fixture = try LegacyImportFixture(testCase: self)
    try fixture.writeOnboarding(
      tunnelID: "tunnel_" + String(repeating: "e", count: 32)
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o644)],
      ofItemAtPath: fixture.onboardingURL.path
    )
    let store = try fixture.store()

    do {
      _ = try await LegacyConfigurationImporter(
        legacyRootURL: fixture.legacyRoot,
        store: store
      ).importIfNeeded()
      XCTFail("Expected an insecure legacy file to be rejected")
    } catch {
      XCTAssertEqual(
        error as? LegacyImportError,
        .insecureSourceFile(LegacySourceFiles.onboardingName)
      )
    }
    let markerExists = try await store.hasConfigurationImportMarker(
      LegacyConfigurationImporter.markerKey
    )
    XCTAssertFalse(markerExists)
  }

  func testRepositoryPathReplacementAfterValidationIsRejected() throws {
    let fixture = try LegacyImportFixture(testCase: self)
    let original = try fixture.project(id: "validated-project")
    try fixture.writeRepository(projects: [original])
    let directory = try XCTUnwrap(
      LegacySourceFiles(rootURL: fixture.legacyRoot).openDirectory()
    )
    let file = try XCTUnwrap(directory.repositoryFile())

    let archivedURL = fixture.root.appending(
      path: "archived-application.sqlite",
      directoryHint: .notDirectory
    )
    try FileManager.default.moveItem(at: fixture.repositoryURL, to: archivedURL)
    let replacementRoot = try fixture.createDirectory("replacement")
    let replacement = try fixture.project(
      id: "replacement-project",
      rootURL: replacementRoot
    )
    try fixture.writeRepository(projects: [replacement])

    XCTAssertThrowsError(
      try LegacyRepositoryReader(
        file: file,
        importDate: Date(timeIntervalSince1970: 1_900_000_000)
      ).read()
    ) { error in
      XCTAssertEqual(
        error as? LegacyImportError,
        .insecureSourceFile(LegacySourceFiles.repositoryName)
      )
    }
  }

  func testRepositorySidecarIsRejectedWithoutImportingPartialData() async throws {
    let fixture = try LegacyImportFixture(testCase: self)
    let project = try fixture.project(id: "sidecar-project")
    try fixture.writeRepository(projects: [project])
    let sidecarURL = fixture.legacyRoot.appending(
      path: "application.sqlite-wal",
      directoryHint: .notDirectory
    )
    try Data([0x01]).write(to: sidecarURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: sidecarURL.path
    )
    let store = try fixture.store()

    do {
      _ = try await LegacyConfigurationImporter(
        legacyRootURL: fixture.legacyRoot,
        store: store
      ).importIfNeeded()
      XCTFail("Expected a repository sidecar to fail closed")
    } catch {
      XCTAssertEqual(
        error as? LegacyImportError,
        .insecureSourceFile(LegacySourceFiles.repositoryName)
      )
    }
    let projects = try await store.projects()
    let markerExists = try await store.hasConfigurationImportMarker(
      LegacyConfigurationImporter.markerKey
    )
    XCTAssertTrue(projects.isEmpty)
    XCTAssertFalse(markerExists)
  }

  func testImportBatchRollsBackWhenMarkerInsertFails() async throws {
    let fixture = try LegacyImportFixture(testCase: self)
    let store = try fixture.store()
    let date = Date(timeIntervalSince1970: 1_900_000_000)
    let project = try ServiceProjectRecord(
      id: ProjectID(rawValue: "rollback-project"),
      name: "Rollback Project",
      root: ServiceRootIdentity(capturing: fixture.projectRoot),
      accessPolicy: .init(),
      createdAt: date,
      updatedAt: date
    )
    let marker = try ServiceSettingRecord(
      key: LegacyConfigurationImporter.markerKey,
      value: "1",
      updatedAt: date
    )
    try await store.installRejectingImportMarkerTrigger()

    do {
      _ = try await store.importConfiguration(
        ServiceConfigurationImportBatch(
          marker: marker,
          projects: [project],
          settings: [
            try ServiceSettingRecord(
              key: ServiceSettingKey.tunnelEnabled.rawValue,
              value: "0",
              updatedAt: date
            )
          ]
        )
      )
      XCTFail("Expected the injected marker failure to roll back the import")
    } catch {
      XCTAssertEqual(error as? ServiceStoreError, .storageFailure)
    }
    let projects = try await store.projects()
    let enabled = try await store.setting(key: ServiceSettingKey.tunnelEnabled.rawValue)
    let markerExists = try await store.hasConfigurationImportMarker(marker.key)
    XCTAssertTrue(projects.isEmpty)
    XCTAssertNil(enabled)
    XCTAssertFalse(markerExists)
  }
}

extension SimpleServiceStore {
  fileprivate func installRejectingImportMarkerTrigger() throws {
    try database.write { db in
      try db.execute(
        sql: """
          CREATE TEMP TRIGGER reject_configuration_import_marker
          BEFORE INSERT ON bridge_service_settings
          WHEN NEW.setting_key = 'migration.legacy-v1.completed'
          BEGIN
            SELECT RAISE(ABORT, 'injected import failure');
          END;
          """
      )
    }
  }
}
