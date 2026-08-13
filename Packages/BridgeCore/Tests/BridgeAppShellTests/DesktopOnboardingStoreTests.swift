import Darwin
import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopOnboardingStoreTests: XCTestCase {
  func testRoundTripUsesPrivateFileAndPersistsNoCredentialFields() throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    _ = try DesktopDataStore.prepare(at: directory)
    let store = DesktopOnboardingStore(directoryURL: directory)
    var record = DesktopOnboardingRecord.fresh()
    record.currentStep = .completion
    record.connectionMode = .localDevelopment
    record.projectID = "prj_test"
    record.projectName = "Bridge"
    record.securityDefaultsSaved = true
    record.connectionTestSucceeded = true
    record.completed = true

    try store.save(record)

    XCTAssertEqual(try store.load(), record)
    let stateURL = directory.appendingPathComponent("onboarding.json")
    var metadata = stat()
    XCTAssertEqual(lstat(stateURL.path, &metadata), 0)
    XCTAssertEqual(metadata.st_uid, getuid())
    XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
    XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    let persisted = String(decoding: try Data(contentsOf: stateURL), as: UTF8.self)
    XCTAssertFalse(persisted.localizedCaseInsensitiveContains("runtimeKey"))
    XCTAssertFalse(persisted.localizedCaseInsensitiveContains("authenticationSecret"))
    XCTAssertFalse(persisted.localizedCaseInsensitiveContains("mcpPathSecret"))
  }

  func testLoadRejectsSymlinkedStateFile() throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let paths = try DesktopDataStore.prepare(at: directory)
    let stateURL = directory.appendingPathComponent("onboarding.json")
    try FileManager.default.createSymbolicLink(
      at: stateURL,
      withDestinationURL: paths.eventStoreURL
    )

    XCTAssertThrowsError(try DesktopOnboardingStore(directoryURL: directory).load()) { error in
      XCTAssertEqual(error as? DesktopOnboardingStoreError, .insecureStateFile)
    }
  }

  func testLoadRejectsImpossibleCompletedState() throws {
    let directory = temporaryDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    _ = try DesktopDataStore.prepare(at: directory)
    var record = DesktopOnboardingRecord.fresh()
    record.completed = true
    let data = try JSONEncoder().encode(record)
    let stateURL = directory.appendingPathComponent("onboarding.json")
    try data.write(to: stateURL, options: .atomic)
    XCTAssertEqual(chmod(stateURL.path, 0o600), 0)

    XCTAssertThrowsError(try DesktopOnboardingStore(directoryURL: directory).load()) { error in
      XCTAssertEqual(error as? DesktopOnboardingStoreError, .corruptState)
    }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-onboarding-store-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}
