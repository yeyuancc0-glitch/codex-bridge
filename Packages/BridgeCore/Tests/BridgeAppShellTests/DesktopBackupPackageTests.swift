import Darwin
import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopBackupPackageTests: XCTestCase {
  func testCreateWritesVersionedPrivatePackageAndValidates() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let created = try DesktopBackupPackage.create(
      from: fixture.data,
      at: fixture.package,
      now: Date(timeIntervalSince1970: 1)
    )
    let validated = try DesktopBackupPackage.validate(at: fixture.package)

    XCTAssertEqual(created, validated)
    XCTAssertEqual(validated.schemaVersion, DesktopBackupPackage.schemaVersion)
    XCTAssertEqual(
      validated.entries.map(\.name),
      DesktopBackupPackage.allowedEntryNames.sorted()
    )
    XCTAssertEqual(try mode(of: fixture.package), 0o700)
    for entry in validated.entries + [
      .init(
        name: DesktopBackupPackage.manifestFileName,
        byteCount: 0,
        sha256: ""
      )
    ] {
      XCTAssertEqual(try mode(of: fixture.package.appendingPathComponent(entry.name)), 0o600)
    }
  }

  func testValidateRejectsUnexpectedEntry() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try DesktopBackupPackage.create(from: fixture.data, at: fixture.package)
    let extra = fixture.package.appendingPathComponent("unexpected")
    try Data("unexpected".utf8).write(to: extra)
    chmod(extra.path, S_IRUSR | S_IWUSR)
    XCTAssertEqual(try mode(of: extra), 0o600)

    XCTAssertThrowsError(try DesktopBackupPackage.validate(at: fixture.package)) { error in
      XCTAssertEqual(error as? DesktopBackupPackageError, .unexpectedEntry("unexpected"))
    }
  }

  func testValidateRejectsTamperedEntryDigest() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try DesktopBackupPackage.create(from: fixture.data, at: fixture.package)
    let entry = fixture.package.appendingPathComponent("application.sqlite")
    try Data("tampered".utf8).write(to: entry)
    chmod(entry.path, S_IRUSR | S_IWUSR)

    XCTAssertThrowsError(try DesktopBackupPackage.validate(at: fixture.package)) { error in
      XCTAssertEqual(error as? DesktopBackupPackageError, .digestMismatch("application.sqlite"))
    }
  }

  func testValidateRejectsSymlinkEntryAndDoesNotReadTarget() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try DesktopBackupPackage.create(from: fixture.data, at: fixture.package)
    let entry = fixture.package.appendingPathComponent("application.sqlite")
    let protected = fixture.root.appendingPathComponent("protected.sqlite")
    try Data("protected".utf8).write(to: protected)
    chmod(protected.path, S_IRUSR | S_IWUSR)
    try FileManager.default.removeItem(at: entry)
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: protected)

    XCTAssertThrowsError(try DesktopBackupPackage.validate(at: fixture.package)) { error in
      XCTAssertEqual(
        error as? DesktopBackupPackageError,
        .insecureEntry("application.sqlite")
      )
    }
    XCTAssertEqual(try Data(contentsOf: protected), Data("protected".utf8))
  }

  func testCreateRejectsSourceSymlinkAndDestinationSymlink() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let source = fixture.data.appendingPathComponent("application.sqlite")
    let protected = fixture.root.appendingPathComponent("source-target.sqlite")
    try Data("protected".utf8).write(to: protected)
    chmod(protected.path, S_IRUSR | S_IWUSR)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: protected)
    XCTAssertThrowsError(
      try DesktopBackupPackage.create(from: fixture.data, at: fixture.package)
    ) { error in
      XCTAssertEqual(error as? DesktopBackupPackageError, .insecureEntry("application.sqlite"))
    }

    try FileManager.default.removeItem(at: source)
    try Data("restored-source".utf8).write(to: source)
    chmod(source.path, S_IRUSR | S_IWUSR)
    let destination = fixture.root.appendingPathComponent("backup-link")
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: protected)
    XCTAssertThrowsError(
      try DesktopBackupPackage.create(from: fixture.data, at: destination)
    ) { error in
      XCTAssertEqual(error as? DesktopBackupPackageError, .destinationExists)
    }
    XCTAssertEqual(try Data(contentsOf: protected), Data("protected".utf8))
  }

  func testValidateRejectsPermissiveManifest() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try DesktopBackupPackage.create(from: fixture.data, at: fixture.package)
    let manifest = fixture.package.appendingPathComponent(DesktopBackupPackage.manifestFileName)
    XCTAssertEqual(chmod(manifest.path, S_IRUSR | S_IWUSR | S_IRGRP), 0)

    XCTAssertThrowsError(try DesktopBackupPackage.validate(at: fixture.package)) { error in
      XCTAssertEqual(
        error as? DesktopBackupPackageError,
        .insecureEntry(DesktopBackupPackage.manifestFileName)
      )
    }
  }

  func testValidateRejectsUnsupportedManifestVersion() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try DesktopBackupPackage.create(from: fixture.data, at: fixture.package)
    let manifest = fixture.package.appendingPathComponent(DesktopBackupPackage.manifestFileName)
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let updated = original.replacingOccurrences(
      of: "\"schema_version\":1",
      with: "\"schema_version\":2"
    )
    try Data(updated.utf8).write(to: manifest)
    chmod(manifest.path, S_IRUSR | S_IWUSR)

    XCTAssertThrowsError(try DesktopBackupPackage.validate(at: fixture.package)) { error in
      XCTAssertEqual(error as? DesktopBackupPackageError, .unsupportedVersion(2))
    }
  }

  private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-backup-package-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let data = root.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(
      at: data,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    for name in DesktopBackupPackage.allowedEntryNames.sorted() {
      let url = data.appendingPathComponent(name)
      try Data("fixture-\(name)".utf8).write(to: url)
      guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    return Fixture(
      root: root,
      data: data,
      package: root.appendingPathComponent("CodexBridge.backup", isDirectory: true)
    )
  }

  private func mode(of url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return metadata.st_mode & 0o777
  }
}

private struct Fixture {
  let root: URL
  let data: URL
  let package: URL
}
