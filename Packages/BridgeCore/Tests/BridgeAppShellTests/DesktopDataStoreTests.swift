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

    _ = try await DesktopComposition.make(dataDirectoryURL: directory)

    let artifacts = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    XCTAssertFalse(artifacts.isEmpty)
    for artifact in artifacts {
      var metadata = stat()
      XCTAssertEqual(lstat(artifact.path, &metadata), 0)
      XCTAssertEqual(metadata.st_uid, getuid())
      XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
      XCTAssertEqual(metadata.st_mode & 0o777, 0o600, artifact.lastPathComponent)
    }
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
