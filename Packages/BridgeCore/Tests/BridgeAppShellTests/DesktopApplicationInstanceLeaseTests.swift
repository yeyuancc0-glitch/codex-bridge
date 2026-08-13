import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopApplicationInstanceLeaseTests: XCTestCase {
  func testOnlyOneLeaseOwnsThePrivateDataDirectory() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try DesktopApplicationInstanceLease(directoryURL: directory)

    XCTAssertThrowsError(try DesktopApplicationInstanceLease(directoryURL: directory)) { error in
      XCTAssertEqual(error as? DesktopApplicationInstanceLeaseError, .alreadyRunning)
    }

    first.release()
    let replacement = try DesktopApplicationInstanceLease(directoryURL: directory)
    replacement.release()
  }

  func testLeaseRejectsSymlinkAndPermissiveExistingFile() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockURL = directory.appendingPathComponent("application-instance.lock")
    let targetURL = directory.appendingPathComponent("target")
    XCTAssertTrue(FileManager.default.createFile(atPath: targetURL.path, contents: Data()))
    try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: targetURL)
    XCTAssertThrowsError(try DesktopApplicationInstanceLease(directoryURL: directory)) { error in
      XCTAssertEqual(error as? DesktopApplicationInstanceLeaseError, .insecureFile)
    }

    try FileManager.default.removeItem(at: lockURL)
    XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o644)],
      ofItemAtPath: lockURL.path
    )
    XCTAssertThrowsError(try DesktopApplicationInstanceLease(directoryURL: directory)) { error in
      XCTAssertEqual(error as? DesktopApplicationInstanceLeaseError, .insecureFile)
    }
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-bridge-instance-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    return directory
  }
}
