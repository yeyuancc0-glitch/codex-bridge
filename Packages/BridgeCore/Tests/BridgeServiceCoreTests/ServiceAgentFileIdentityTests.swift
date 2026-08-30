import Foundation
import XCTest

@testable import BridgeServiceCore

final class ServiceAgentFileIdentityTests: XCTestCase {
  func testCapturesTrustedArtifactThroughServiceAdapter() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "artifact.bin")
    try Data("trusted-artifact".utf8).write(to: file)

    let identity = try ServiceAgentFileIdentity(capturing: file.path)

    XCTAssertEqual(identity.canonicalPath, file.standardizedFileURL.path)
    XCTAssertEqual(identity.fileSize, 16)
    XCTAssertEqual(identity.sha256.count, 64)
  }

  func testPreservesCanonicalSymbolicLinkResolution() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "target.bin")
    let link = directory.appending(path: "link.bin")
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let identity = try ServiceAgentFileIdentity(capturing: link.path)
    XCTAssertEqual(identity.canonicalPath, target.standardizedFileURL.path)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-agent-file-identity-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
