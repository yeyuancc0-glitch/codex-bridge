import Foundation
import XCTest

@testable import BridgeSecurity

final class PathSecurityTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appending(path: "codex-bridge-security-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL {
      try? FileManager.default.removeItem(at: rootURL)
    }
  }

  func testRelativePathRejectsTraversalAndAbsoluteForms() {
    for value in ["../secret", "a/../secret", "/etc/passwd", "~/secret", "file:///tmp/x", "a//b"] {
      XCTAssertThrowsError(try SecureRelativePath(value), value)
    }
    XCTAssertNoThrow(try SecureRelativePath("%2e%2e/config.txt"))
  }

  func testResolvesInternalFileAndBlocksSiblingPrefix() throws {
    let file = rootURL.appending(path: "Sources/App.swift")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("struct App {}\n".utf8).write(to: file)
    let resolver = try makeResolver()

    let resolved = try resolver.resolve(SecureRelativePath("Sources/App.swift"))

    XCTAssertEqual(resolved.canonicalURL.path, file.path)
  }

  func testBlocksSymlinkEscapeAndSensitiveAlias() throws {
    let external = FileManager.default.temporaryDirectory
      .appending(path: "codex-bridge-external-\(UUID().uuidString)")
    let sensitive = rootURL.appending(path: ".env")
    let externalLink = rootURL.appending(path: "external")
    let sensitiveLink = rootURL.appending(path: "safe-name")
    try Data("outside".utf8).write(to: external)
    try Data("SECRET=value".utf8).write(to: sensitive)
    try FileManager.default.createSymbolicLink(at: externalLink, withDestinationURL: external)
    try FileManager.default.createSymbolicLink(at: sensitiveLink, withDestinationURL: sensitive)
    defer { try? FileManager.default.removeItem(at: external) }
    let resolver = try makeResolver()

    XCTAssertThrowsError(try resolver.resolve(SecureRelativePath("external"))) { error in
      XCTAssertEqual(error as? PathSecurityError, .pathEscapeBlocked)
    }
    XCTAssertThrowsError(try resolver.resolve(SecureRelativePath("safe-name"))) { error in
      XCTAssertEqual(error as? PathSecurityError, .sensitiveFileBlocked)
    }
  }

  func testDetectsRootIdentityReplacement() throws {
    let registered = try RegisteredRoot(capturing: rootURL)
    let oldRoot = rootURL.appendingPathExtension("old")
    try FileManager.default.moveItem(at: rootURL, to: oldRoot)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: oldRoot) }

    XCTAssertThrowsError(try registered.validateCurrentIdentity()) { error in
      XCTAssertEqual(error as? PathSecurityError, .rootIdentityChanged)
    }
  }

  func testReadsTextAndRejectsBinaryAndOversizedFiles() throws {
    try Data("one\ntwo\nthree".utf8).write(to: rootURL.appending(path: "text.txt"))
    try Data([0x00, 0x01]).write(to: rootURL.appending(path: "binary.dat"))
    try Data(repeating: 0x61, count: 17).write(to: rootURL.appending(path: "large.txt"))
    let resolver = try makeResolver()
    let reader = SecureFileReader(maximumBytes: 16, maximumLines: 2)

    let text = try reader.read(SecureRelativePath("text.txt"), through: resolver)
    XCTAssertEqual(text.text, "one\ntwo")
    XCTAssertTrue(text.truncated)
    XCTAssertThrowsError(try reader.read(SecureRelativePath("binary.dat"), through: resolver))
    XCTAssertThrowsError(try reader.read(SecureRelativePath("large.txt"), through: resolver))
  }

  func testBlocksFilesInsideSensitiveDirectories() throws {
    let cookiesDirectory = rootURL.appending(path: "Browser/Cookies")
    try FileManager.default.createDirectory(
      at: cookiesDirectory,
      withIntermediateDirectories: true
    )
    try Data("session=value".utf8).write(to: cookiesDirectory.appending(path: "store.db"))
    let resolver = try makeResolver()

    XCTAssertThrowsError(
      try resolver.resolve(SecureRelativePath("Browser/Cookies/store.db"))
    ) { error in
      XCTAssertEqual(error as? PathSecurityError, .sensitiveFileBlocked)
    }
  }

  func testRejectsFileReplacedAfterResolution() throws {
    let file = rootURL.appending(path: "mutable.txt")
    let original = rootURL.appending(path: "original.txt")
    try Data("original".utf8).write(to: file)
    let resolver = try makeResolver()
    let resolved = try resolver.resolve(SecureRelativePath("mutable.txt"))

    try FileManager.default.moveItem(at: file, to: original)
    try Data("replacement".utf8).write(to: file)
    let reader = SecureFileReader()

    XCTAssertThrowsError(
      try reader.readResolved(resolved, root: resolver.root)
    ) { error in
      XCTAssertEqual(error as? PathSecurityError, .fileIdentityChanged)
    }
  }

  private func makeResolver() throws -> ProjectPathResolver {
    ProjectPathResolver(root: try RegisteredRoot(capturing: rootURL))
  }
}
