import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation
import XCTest

@testable import BridgeFiles

final class ProjectFileServiceTests: XCTestCase {
  func testReadsRequestedLinesAndRedactsSuspectedSecret() async throws {
    try await withFixture { fixture in
      try fixture.write(
        "Sources/App.swift",
        "first\nAPI_KEY=1234567890123456\nthird\nfourth"
      )
      let result = try await fixture.service.read(
        ProjectFileReadRequest(
          projectID: fixture.projectID,
          relativePath: "Sources/App.swift",
          lineRange: try FileLineRange(startLine: 2, lineCount: 2)
        )
      )

      XCTAssertEqual(result.relativePath, "Sources/App.swift")
      XCTAssertEqual(result.startLine, 2)
      XCTAssertEqual(result.endLine, 3)
      XCTAssertEqual(result.content, "[REDACTED: suspected secret]\nthird")
      XCTAssertEqual(result.redactedLineCount, 1)
      XCTAssertEqual(result.nextStartLine, 4)
    }
  }

  func testReadDefaultsToLargePage() async throws {
    try await withFixture { fixture in
      let text = (1...301).map { "line \($0)" }.joined(separator: "\n")
      try fixture.write("many.txt", text)
      let result = try await fixture.service.read(
        ProjectFileReadRequest(projectID: fixture.projectID, relativePath: "many.txt")
      )

      XCTAssertEqual(result.content.split(separator: "\n").count, 301)
      XCTAssertFalse(result.truncated)
      XCTAssertNil(result.nextStartLine)
    }
  }

  func testReadTruncatesBeyondLineCapAndReportsNextStartLine() async throws {
    try await withFixture { fixture in
      let text = (1...12_000).map { "l\($0)" }.joined(separator: "\n")
      try fixture.write("huge.txt", text)
      let result = try await fixture.service.read(
        ProjectFileReadRequest(
          projectID: fixture.projectID,
          relativePath: "huge.txt",
          lineRange: .maximum
        )
      )

      XCTAssertEqual(result.content.split(separator: "\n").count, 10_000)
      XCTAssertTrue(result.truncated)
      XCTAssertEqual(result.nextStartLine, 10_001)
    }
  }

  func testReadRejectsAbsoluteSensitiveBinaryAndOversizedFiles() async throws {
    try await withFixture { fixture in
      try fixture.write(".env", "SECRET=value")
      try fixture.writeData("binary.dat", Data([0x41, 0x00, 0x42]))
      try fixture.write("large.txt", String(repeating: "x", count: 200 * 1_024 + 1))

      await assertThrowsErrorAsync(
        try await fixture.service.read(
          ProjectFileReadRequest(projectID: fixture.projectID, relativePath: "/etc/passwd")
        )
      )
      await assertThrowsErrorAsync(
        try await fixture.service.read(
          ProjectFileReadRequest(projectID: fixture.projectID, relativePath: ".env")
        )
      )
      await assertThrowsErrorAsync(
        try await fixture.service.read(
          ProjectFileReadRequest(projectID: fixture.projectID, relativePath: "binary.dat")
        )
      )
      await assertThrowsErrorAsync(
        try await fixture.service.read(
          ProjectFileReadRequest(projectID: fixture.projectID, relativePath: "large.txt")
        )
      )
    }
  }

  func testReadAllowsInternalSymlinkButBlocksEscape() async throws {
    try await withFixture { fixture in
      try fixture.write("real/value.txt", "inside")
      let outside = fixture.root.deletingLastPathComponent().appending(path: "outside.txt")
      try "outside".write(to: outside, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: outside) }
      try FileManager.default.createSymbolicLink(
        at: fixture.root.appending(path: "inside-link.txt"),
        withDestinationURL: fixture.root.appending(path: "real/value.txt")
      )
      try FileManager.default.createSymbolicLink(
        at: fixture.root.appending(path: "outside-link.txt"),
        withDestinationURL: outside
      )

      let result = try await fixture.service.read(
        ProjectFileReadRequest(projectID: fixture.projectID, relativePath: "inside-link.txt")
      )
      XCTAssertEqual(result.content, "inside")
      await assertThrowsErrorAsync(
        try await fixture.service.read(
          ProjectFileReadRequest(projectID: fixture.projectID, relativePath: "outside-link.txt")
        )
      )
    }
  }

  func testReadDetectsRegisteredRootReplacement() async throws {
    let fixture = try await Fixture.make()
    let original = fixture.root.appendingPathExtension("original")
    defer {
      try? FileManager.default.removeItem(at: fixture.root)
      try? FileManager.default.removeItem(at: original)
    }
    try fixture.write("value.txt", "old")
    try FileManager.default.moveItem(at: fixture.root, to: original)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    try "new".write(
      to: fixture.root.appending(path: "value.txt"),
      atomically: true,
      encoding: .utf8
    )

    await assertThrowsErrorAsync(
      try await fixture.service.read(
        ProjectFileReadRequest(projectID: fixture.projectID, relativePath: "value.txt")
      )
    ) { error in
      XCTAssertEqual(error as? PathSecurityError, .rootIdentityChanged)
    }
  }

  func testServiceRejectsUnknownProjectAndDeniedReadPolicy() async throws {
    let denied = try await Fixture.make(
      accessPolicy: ProjectAccessPolicy(read: .denied)
    )
    defer { try? FileManager.default.removeItem(at: denied.root) }
    try denied.write("value.txt", "value")

    await assertThrowsErrorAsync(
      try await denied.service.read(
        ProjectFileReadRequest(projectID: denied.projectID, relativePath: "value.txt")
      )
    ) { error in
      XCTAssertEqual(error as? ProjectFileError, .readNotAllowed)
    }
    await assertThrowsErrorAsync(
      try await denied.service.read(
        ProjectFileReadRequest(
          projectID: ProjectID(rawValue: "prj_not_registered"),
          relativePath: "value.txt"
        )
      )
    ) { error in
      XCTAssertEqual(error as? ProjectFileError, .unknownProject)
    }
  }

  func testSearchPaginatesAndBindsCursorToQuery() async throws {
    try await withFixture { fixture in
      try fixture.write("a.txt", "needle a")
      try fixture.write("b.txt", "needle b")
      try fixture.write("c.txt", "needle c")
      let request = try ProjectFileSearchRequest(
        projectID: fixture.projectID,
        query: "needle",
        limit: 1
      )
      let first = try await fixture.service.search(request)
      let cursor = try XCTUnwrap(first.nextCursor)
      let second = try await fixture.service.search(
        try ProjectFileSearchRequest(
          projectID: fixture.projectID,
          query: "needle",
          limit: 1,
          cursor: cursor
        )
      )

      XCTAssertEqual(first.matches.map(\.relativePath), ["a.txt"])
      XCTAssertEqual(second.matches.map(\.relativePath), ["b.txt"])
      await assertThrowsErrorAsync(
        try await fixture.service.search(
          try ProjectFileSearchRequest(
            projectID: fixture.projectID,
            query: "different",
            limit: 1,
            cursor: cursor
          )
        )
      ) { error in
        XCTAssertEqual(error as? ProjectFileError, .invalidCursor)
      }
    }
  }

  func testSearchUsesDefaultFiftyMatchLimitAndRejectsExcessiveLimit() async throws {
    try await withFixture { fixture in
      for index in 0..<60 {
        try fixture.write(String(format: "%02d.txt", index), "hit")
      }
      let result = try await fixture.service.search(
        try ProjectFileSearchRequest(projectID: fixture.projectID, query: "hit")
      )
      XCTAssertEqual(result.matches.count, 50)
      XCTAssertNotNil(result.nextCursor)

      await assertThrowsErrorAsync(
        try await fixture.service.search(
          try ProjectFileSearchRequest(projectID: fixture.projectID, query: "hit", limit: 201)
        )
      ) { error in
        XCTAssertEqual(error as? ProjectFileError, .invalidSearchRequest)
      }
    }
  }

  func testSearchSkipsIgnoredSensitiveBinaryLargeAndForbiddenPaths() async throws {
    try await withFixture(forbiddenPatterns: [try ForbiddenPathPattern("private/**")]) { fixture in
      try fixture.write("Sources/visible.swift", "find me")
      try fixture.write("node_modules/dependency.js", "find me")
      try fixture.write("private/note.txt", "find me")
      try fixture.write(".env.local", "find me")
      try fixture.writeData("binary.dat", Data([0x00, 0x66, 0x69, 0x6E, 0x64]))
      try fixture.write("large.txt", String(repeating: "find ", count: 50_000))

      let result = try await fixture.service.search(
        try ProjectFileSearchRequest(projectID: fixture.projectID, query: "find me")
      )
      XCTAssertEqual(result.matches.map(\.relativePath), ["Sources/visible.swift"])
      XCTAssertTrue(result.matches.allSatisfy { !$0.relativePath.hasPrefix("/") })
    }
  }

  func testSearchScopesToRelativeDirectory() async throws {
    try await withFixture { fixture in
      try fixture.write("Sources/a.swift", "target")
      try fixture.write("Tests/a.swift", "target")
      let result = try await fixture.service.search(
        try ProjectFileSearchRequest(
          projectID: fixture.projectID,
          query: "target",
          relativeDirectory: "Sources"
        )
      )
      XCTAssertEqual(result.matches.map(\.relativePath), ["Sources/a.swift"])
    }
  }

  func testSearchRedactsMatchingSecretLine() async throws {
    try await withFixture { fixture in
      try fixture.write("config.txt", "access_token: abcdefghijklmnopqrstuvwxyz")
      let result = try await fixture.service.search(
        try ProjectFileSearchRequest(projectID: fixture.projectID, query: "access_token")
      )
      XCTAssertEqual(result.matches.first?.preview, "[REDACTED: suspected secret]")
      XCTAssertEqual(result.matches.first?.redacted, true)
      XCTAssertFalse(result.matches.first?.preview.contains("abcdefghijklmnopqrstuvwxyz") ?? true)
    }
  }

  func testSearchPrioritizesTrackedIndexWithoutRunningRepositoryHook() async throws {
    try await withFixture { fixture in
      try fixture.write("z-tracked.txt", "match")
      try fixture.write("a-untracked.txt", "match")
      try runGit(["init", "-q"], at: fixture.root)
      try runGit(["add", "--", "z-tracked.txt"], at: fixture.root)
      let hookMarker = fixture.root.appending(path: "hook-ran")
      try fixture.write(".git/hooks/pre-commit", "#!/bin/sh\ntouch hook-ran\n")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: fixture.root.appending(path: ".git/hooks/pre-commit").path
      )

      let result = try await fixture.service.search(
        try ProjectFileSearchRequest(
          projectID: fixture.projectID,
          query: "match",
          limit: 1
        )
      )
      XCTAssertEqual(result.matches.map(\.relativePath), ["z-tracked.txt"])
      XCTAssertTrue(result.usedTrackedPathPriority)
      XCTAssertFalse(FileManager.default.fileExists(atPath: hookMarker.path))
    }
  }

  func testSearchSkipsSymbolicLinksDuringEnumeration() async throws {
    try await withFixture { fixture in
      try fixture.write("real.txt", "needle")
      try FileManager.default.createSymbolicLink(
        at: fixture.root.appending(path: "alias.txt"),
        withDestinationURL: fixture.root.appending(path: "real.txt")
      )
      let result = try await fixture.service.search(
        try ProjectFileSearchRequest(projectID: fixture.projectID, query: "needle")
      )
      XCTAssertEqual(result.matches.map(\.relativePath), ["real.txt"])
    }
  }

  func testSearchFailsClosedWhenCandidateLimitIsExceeded() async throws {
    let limits = try ProjectFileLimits(
      maximumCandidateFiles: 2,
      maximumEnumeratedEntries: 10
    )
    try await withFixture(limits: limits) { fixture in
      try fixture.write("a.txt", "hit")
      try fixture.write("b.txt", "hit")
      try fixture.write("c.txt", "hit")
      await assertThrowsErrorAsync(
        try await fixture.service.search(
          try ProjectFileSearchRequest(projectID: fixture.projectID, query: "hit")
        )
      ) { error in
        XCTAssertEqual(error as? ProjectFileError, .candidateLimitExceeded)
      }
    }
  }

  func testSearchFitsEncodedResponseLimitWithoutDroppingContinuation() async throws {
    let limits = try ProjectFileLimits(maximumResponseBytes: 512)
    try await withFixture(limits: limits) { fixture in
      for index in 0..<5 {
        let name = "\(String(repeating: "long-path-", count: 8))-\(index).txt"
        try fixture.write(name, "bounded match \(index)")
      }
      let result = try await fixture.service.search(
        try ProjectFileSearchRequest(
          projectID: fixture.projectID,
          query: "bounded match",
          limit: 5
        )
      )

      XCTAssertLessThanOrEqual(try JSONEncoder().encode(result).count, 512)
      XCTAssertFalse(result.matches.isEmpty)
      XCTAssertNotNil(result.nextCursor)
    }
  }
}

private struct Fixture {
  let root: URL
  let repository: InMemoryProjectRepository
  let projectID: ProjectID
  let service: RestrictedProjectFileService

  static func make(
    limits: ProjectFileLimits = .default,
    forbiddenPatterns: [ForbiddenPathPattern] = [],
    accessPolicy: ProjectAccessPolicy = .init()
  ) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "bridge-files-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = InMemoryProjectRepository()
    let registry = ProjectRegistry(repository: repository)
    let summary = try await registry.register(
      local: try LocalProjectRegistration(
        name: "Fixture",
        rootURL: root,
        accessPolicy: accessPolicy,
        forbiddenPatterns: forbiddenPatterns
      )
    )
    return Fixture(
      root: root,
      repository: repository,
      projectID: summary.id,
      service: RestrictedProjectFileService(repository: repository, limits: limits)
    )
  }

  func write(_ path: String, _ contents: String) throws {
    try writeData(path, Data(contents.utf8))
  }

  func writeData(_ path: String, _ contents: Data) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try contents.write(to: url)
  }
}

private func withFixture(
  limits: ProjectFileLimits = .default,
  forbiddenPatterns: [ForbiddenPathPattern] = [],
  operation: (Fixture) async throws -> Void
) async throws {
  let fixture = try await Fixture.make(limits: limits, forbiddenPatterns: forbiddenPatterns)
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try await operation(fixture)
}

private func runGit(_ arguments: [String], at root: URL) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
  process.currentDirectoryURL = root
  process.environment = [
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "LC_ALL": "C",
  ]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw NSError(domain: "BridgeFilesTests.Git", code: Int(process.terminationStatus))
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (Error) -> Void = { _ in },
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
