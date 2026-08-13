import BridgePresentation
import BridgeTunnel
import Darwin
import Foundation
import XCTest

@testable import BridgeAppShell

final class DesktopSupportBundleWriterTests: XCTestCase {
  func testBundleRedactsSensitiveDiagnosticTextAndOmitsEndpoint() throws {
    let sensitive = "password=actual-secret-value /Users/alice/private"
    let data = try DesktopSupportBundle.build(
      diagnostics: [
        LogEntryPresentation(
          id: "diagnostic-1",
          timestamp: Date(timeIntervalSince1970: 1),
          source: sensitive,
          severity: .failed,
          message: sensitive
        )
      ],
      connection: DesktopTransportHealth(
        lifecycle: .ready,
        acceptsRemoteSubmissions: true,
        endpointDescription: "https://private.example/mcp",
        localMCPURL: URL(string: "http://127.0.0.1:1234/mcp-secret"),
        actionRequired: false
      ),
      projectCount: 1,
      recentTaskCount: 2,
      generatedAt: Date(timeIntervalSince1970: 2)
    )

    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains("actual-secret-value"))
    XCTAssertFalse(text.contains("/Users/alice/private"))
    XCTAssertFalse(text.contains("private.example"))
    XCTAssertFalse(text.contains("mcp-secret"))
    XCTAssertTrue(text.contains("[REDACTED_"))
  }

  func testPersistWritesPrivateFileAndExactContents() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("support.json")
    let data = Data("{\"schema_version\":1}".utf8)

    XCTAssertTrue(DesktopSupportBundleWriter.persist(data, at: destination))
    XCTAssertEqual(try Data(contentsOf: destination), data)
    XCTAssertEqual(try mode(of: destination), 0o600)
  }

  func testPersistReplacesDestinationSymlinkWithoutWritingThroughIt() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let protected = directory.appendingPathComponent("protected.json")
    let destination = directory.appendingPathComponent("support.json")
    let original = Data("protected".utf8)
    let support = Data("support".utf8)
    try original.write(to: protected)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: protected)

    XCTAssertTrue(DesktopSupportBundleWriter.persist(support, at: destination))
    XCTAssertEqual(try Data(contentsOf: protected), original)
    XCTAssertEqual(try Data(contentsOf: destination), support)
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
    XCTAssertEqual(try mode(of: destination), 0o600)
  }

  func testPersistRejectsAncestorReplacedBySymlinkAfterResolution() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let approved = root.appendingPathComponent("approved", isDirectory: true)
    let moved = root.appendingPathComponent("approved-moved", isDirectory: true)
    let unapproved = root.appendingPathComponent("unapproved", isDirectory: true)
    try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unapproved, withIntermediateDirectories: true)
    let destination = approved.appendingPathComponent("support.json")

    let persisted = DesktopSupportBundleWriter.persist(
      Data("support".utf8),
      at: destination
    ) {
      try? FileManager.default.moveItem(at: approved, to: moved)
      try? FileManager.default.createSymbolicLink(
        at: approved,
        withDestinationURL: unapproved
      )
    }

    XCTAssertFalse(persisted)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: moved.appendingPathComponent("support.json").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: unapproved.appendingPathComponent("support.json").path)
    )
  }

  private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bridge-support-writer-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func mode(of url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return metadata.st_mode & 0o777
  }
}
