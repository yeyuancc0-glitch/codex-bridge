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

  func testOutboundContentRedactsAbsolutePathsAcrossURLAndMarkdownBoundaries() {
    let input =
      "Open file:////Users/alice/private.txt, [artifact](/Volumes/work/output.log), /Network/Servers/team/repo, /mnt/team/repo, and /dev/null."

    let redacted = OutboundContentSecurity.redacted(input, maximumUTF8Bytes: 4_096)

    XCTAssertFalse(redacted.contains("/Users/"))
    XCTAssertFalse(redacted.contains("/Volumes/"))
    XCTAssertFalse(redacted.contains("/Network/"))
    XCTAssertFalse(redacted.contains("/mnt/"))
    XCTAssertFalse(redacted.contains("/dev/"))
    XCTAssertFalse(OutboundContentSecurity.isSafe(input))
    XCTAssertTrue(OutboundContentSecurity.isSafe("Open Sources/App.swift."))
    XCTAssertTrue(OutboundContentSecurity.isSafe("See https://example.com/docs/setup."))
    XCTAssertFalse(OutboundContentSecurity.isSafe("x-codex-bridge-token"))
    XCTAssertFalse(OutboundContentSecurity.isSafe("file:%2F%2FUsers%2Falice%2Fprivate.txt"))
    XCTAssertFalse(OutboundContentSecurity.isSafe("eyJabcdefgh.abcdefgh.abcdefgh"))
  }

  func testOutboundContentRedactsWholeAbsolutePathContainingSpaces() {
    for input in [
      "Open /Users/My Team/private.txt, then continue.",
      "Open /Users/Alice/Project, Inc/plan.txt, then continue.",
      "Open /Users/Alice/Project (Draft)/plan.txt, then continue.",
      "cwd:/Users/alice/.ssh/id_rsa",
      "working_dir:/Users/alice/.ssh/id_rsa",
      "路径:/Users/alice/.ssh/id_rsa",
      "http:/Users/alice/.ssh/id_rsa",
      "https:/Volumes/private/repo",
      "Read //Users/alice/.ssh/id_rsa",
      "xhttps://Users/alice/.ssh/id_rsa",
      "nothttp://Volumes/private/repo",
      "not_https://Users/alice/.ssh/id_rsa",
      "_https://Volumes/private/repo",
      "1https://Users/alice",
      "中文https://Users/alice",
      "https:///Users/alice/.ssh/id_rsa",
      "https:////Volumes/private",
      "https://?cwd=/Users/alice",
      "http://#x/Users/alice",
      "Read ~/.ssh/id_rsa",
    ] {
      let redacted = OutboundContentSecurity.redacted(input, maximumUTF8Bytes: 4_096)
      XCTAssertFalse(redacted.contains("private.txt"))
      XCTAssertFalse(redacted.contains("plan.txt"))
      XCTAssertFalse(OutboundContentSecurity.isSafe(input))
    }
  }

  func testOutboundContentConsumesAuthenticationHeaderValueDuringRedaction() {
    let inputs = [
      "x-codex-bridge-token: topsecret",
      #"{"x-codex-bridge-token":"topsecret"}"#,
      #"{"api_key":"topsecret"}"#,
      "x-codex-mcp-auth: topsecret",
      "{'password':'abcdefghijklmnop'}",
      #""passwd": "abcdefghijklmnop""#,
      #""client_secret": 1234567890123456"#,
    ]

    for input in inputs {
      let redacted = OutboundContentSecurity.redacted(input, maximumUTF8Bytes: 4_096)
      XCTAssertFalse(redacted.contains("topsecret"))
      XCTAssertFalse(OutboundContentSecurity.isSafe(input))
    }
  }

  func testPrivateKeyBlockIsRejectedAndRedactedByBothPublicEntrypoints() {
    let input = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"

    XCTAssertFalse(OutboundContentSecurity.isSafe(input))
    let redaction = OutboundContentSecurity.redaction(of: input, maximumUTF8Bytes: 4_096)
    XCTAssertEqual(redaction.text, "[REDACTED]\n[REDACTED]\n[REDACTED]")
    XCTAssertEqual(redaction.redactedLineCount, 3)
  }

  func testOutboundRedactionRespectsHardUTF8Limit() {
    for limit in 1...12 {
      let value = OutboundContentSecurity.redacted("你好abcdef", maximumUTF8Bytes: limit)
      XCTAssertLessThanOrEqual(value.utf8.count, limit)
    }
  }

  func testOutboundPathScanHandlesManySafeURLsBeforeUnsafePath() {
    let safeURLs = Array(repeating: "https://example.com/a", count: 4_000).joined(separator: " ")
    let input = safeURLs + " cwd:/Users/alice/private.txt"

    XCTAssertFalse(OutboundContentSecurity.isSafe(input))
    let redacted = OutboundContentSecurity.redacted(input, maximumUTF8Bytes: 128 * 1_024)
    XCTAssertFalse(redacted.contains("/Users/alice/private.txt"))
  }

  func testSourceRedactionHandlesManyStringLiteralsAndSlashes() {
    let input = String(repeating: #""a"/"#, count: 12_000)
    let clock = ContinuousClock()
    let start = clock.now

    let redaction = OutboundContentSecurity.redaction(
      of: input,
      maximumUTF8Bytes: 64 * 1_024,
      preservingSourceSyntax: true
    )

    XCTAssertTrue(redaction.changed)
    XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
  }

  func testOutboundPathScanPreservesOrdinarySourceSyntax() {
    let input =
      "// ordinary comment\n//TODO: later\n/// doc comment\n/* block comment */\nlet quotient = total / count\nlet regex = /secret/i\nreturn /foo/.test(value)"

    let redaction = OutboundContentSecurity.redaction(
      of: input,
      maximumUTF8Bytes: 4_096,
      preservingSourceSyntax: true
    )

    XCTAssertEqual(redaction.text, input)
    XCTAssertEqual(redaction.redactedLineCount, 0)
    XCTAssertFalse(redaction.changed)
    XCTAssertFalse(OutboundContentSecurity.isSafe(input))
    XCTAssertFalse(OutboundContentSecurity.isSafe("cwd = /Users/i"))

    for quotedPath in [
      #"let path = "//Users/alice/private""#,
      #"let path = "///Volumes/fanch/private""#,
      #"let path = "/*Users/alice/private""#,
    ] {
      let quotedRedaction = OutboundContentSecurity.redaction(
        of: quotedPath,
        maximumUTF8Bytes: 4_096,
        preservingSourceSyntax: true
      )
      XCTAssertFalse(quotedRedaction.text.contains("private"))
      XCTAssertTrue(quotedRedaction.changed)
    }
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
