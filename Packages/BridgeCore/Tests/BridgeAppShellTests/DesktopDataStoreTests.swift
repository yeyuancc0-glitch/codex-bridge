import BridgeDomain
import BridgeProjects
import Darwin
import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopDataStoreTests: XCTestCase {
  func testPrepareCreatesPrivateDirectoryAndDatabaseFiles() throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let store = try DesktopDataStore.prepare(at: directory)

    XCTAssertEqual(try permissions(store.directoryURL), 0o700)
    XCTAssertEqual(try permissions(store.eventStoreURL), 0o600)
    XCTAssertEqual(try permissions(store.applicationRepositoryURL), 0o600)
    XCTAssertEqual(try permissions(store.supervisorHomeURL), 0o700)
  }

  func testPrepareRejectsExistingPermissiveDirectory() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o755)]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    XCTAssertThrowsError(try DesktopDataStore.prepare(at: directory)) { error in
      XCTAssertEqual(error as? DesktopDataStoreError, .insecureDirectory)
    }
  }

  func testPrepareRejectsSymlinkedDatabaseFile() throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let store = try DesktopDataStore.prepare(at: directory)
    try FileManager.default.removeItem(at: store.applicationRepositoryURL)
    try FileManager.default.createSymbolicLink(
      at: store.applicationRepositoryURL,
      withDestinationURL: store.eventStoreURL
    )

    XCTAssertThrowsError(try DesktopDataStore.prepare(at: directory)) { error in
      XCTAssertEqual(error as? DesktopDataStoreError, .insecureDatabaseFile)
    }
  }

  func testCompositionKeepsEveryDatabaseArtifactPrivate() async throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let composition = try await DesktopComposition.make(
      dataDirectoryURL: directory,
      system: DataStoreTestSystemService()
    )

    let artifacts = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    XCTAssertFalse(artifacts.isEmpty)
    for artifact in artifacts {
      var metadata = stat()
      XCTAssertEqual(lstat(artifact.path, &metadata), 0)
      XCTAssertEqual(metadata.st_uid, getuid())
      if ["git-patches", "supervisor-home"].contains(artifact.lastPathComponent) {
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o700)
      } else {
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600, artifact.lastPathComponent)
      }
    }
    await composition.shutdown()
  }

  func testCompositionRuntimeResolvesRegisteredProjectWithoutStartingCodex() async throws {
    let directory = temporaryDirectory()
    let projectDirectory = directory.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(
      at: projectDirectory,
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let composition = try await DesktopComposition.make(
      dataDirectoryURL: directory.appendingPathComponent("Data", isDirectory: true),
      system: DataStoreTestSystemService()
    )
    let project = try await composition.registry.register(
      local: LocalProjectRegistration(name: "Project", rootURL: projectDirectory)
    )
    let submission = TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "runtime-location-test"),
      projectID: project.id,
      thread: .new,
      execution: ExecutionOptions(
        model: "test-model",
        effort: "medium",
        permissionMode: "read-only",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(
        enabled: true,
        model: "test-supervisor",
        effort: "medium"
      ),
      contract: TaskContract(goal: "Inspect the project", acceptanceCriteria: ["Done"])
    )

    let keys = try await composition.taskRuntime.lockKeys(for: submission)

    XCTAssertEqual(keys.count, 2)
    XCTAssertTrue(keys.contains(where: { $0.hasPrefix("thread:") }))
    XCTAssertTrue(keys.contains(where: { $0.hasPrefix("worktree:") }))
    await composition.shutdown()
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-app-shell-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func permissions(_ url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileReadUnknown) }
    return metadata.st_mode & 0o777
  }
}

@MainActor
private final class DataStoreTestSystemService: DesktopSystemServing {
  func selectProjectDirectory() async -> URL? { nil }
  func open(_: URL) -> Bool { true }
  func copyToPasteboard(_: String) -> Bool { true }
  func showMainWindow() {}
  func terminateApplication() {}
}
