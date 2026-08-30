import Darwin
import Foundation
import XCTest

@testable import BridgeSecurity

final class SecureFileArtifactSnapshotTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-artifact-snapshot-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func testCapturesIdentityAndDigest() throws {
    let file = directory.appending(path: "artifact.bin")
    try Data("trusted-artifact".utf8).write(to: file)

    let snapshot = try SecureFileArtifactSnapshot(capturing: file.path)

    XCTAssertEqual(snapshot.canonicalPath, file.standardizedFileURL.path)
    XCTAssertEqual(snapshot.fileSize, 16)
    XCTAssertGreaterThan(snapshot.device, 0)
    XCTAssertGreaterThan(snapshot.inode, 0)
    XCTAssertGreaterThan(snapshot.modificationTimeNanoseconds, 0)
    XCTAssertEqual(
      snapshot.sha256, "8d30acc58a72981fec45bdadcb6b84f7ab4224d98df388f87c4edbd1bdfd9284")
  }

  func testCanonicalizesFinalSymbolicLinkBeforeHandle() throws {
    let target = directory.appending(path: "target.bin")
    let link = directory.appending(path: "link.bin")
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let snapshot = try SecureFileArtifactSnapshot(capturing: link.path)
    XCTAssertEqual(snapshot.canonicalPath, target.standardizedFileURL.path)
  }

  func testEnforcesExecutableRequirementAndReadBoundary() throws {
    let file = directory.appending(path: "artifact.bin")
    let data = Data("0123456789".utf8)
    try data.write(to: file)
    XCTAssertEqual(chmod(file.path, 0o600), 0)

    XCTAssertThrowsError(
      try SecureFileArtifactSnapshot(capturing: file.path, requiresExecutable: true)
    ) { error in
      XCTAssertEqual(error as? SecureFileArtifactError, .executableRequired)
    }
    let exact = try SecureFileArtifactSnapshot(
      capturing: file.path,
      maximumBytes: UInt64(data.count)
    )
    XCTAssertEqual(exact.fileSize, UInt64(data.count))
    XCTAssertThrowsError(
      try SecureFileArtifactSnapshot(capturing: file.path, maximumBytes: UInt64(data.count - 1))
    ) { error in
      XCTAssertEqual(error as? SecureFileArtifactError, .fileTooLarge)
    }
  }

  func testReadsRegularFileWithinExplicitBoundary() throws {
    let file = directory.appending(path: "artifact.bin")
    let data = Data("bounded-artifact".utf8)
    try data.write(to: file)

    XCTAssertEqual(
      try SecureFileArtifactReader.read(at: file.path, maximumBytes: data.count),
      data
    )
    XCTAssertThrowsError(
      try SecureFileArtifactReader.read(at: file.path, maximumBytes: data.count - 1)
    ) { error in
      XCTAssertEqual(error as? SecureFileArtifactError, .fileTooLarge)
    }
  }
}
