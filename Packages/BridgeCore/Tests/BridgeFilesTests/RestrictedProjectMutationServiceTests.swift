import BridgeDomain
import BridgeProjects
import BridgeSecurity
import CryptoKit
import Foundation
import XCTest

@testable import BridgeFiles

final class RestrictedProjectMutationServiceTests: XCTestCase {
  private func writeFixture(_ testCase: XCTestCase) async throws -> MutationFixture {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "bridge-mutation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let repository = InMemoryProjectRepository()
    let registry = ProjectRegistry(repository: repository)
    let summary = try await registry.register(
      local: try LocalProjectRegistration(
        name: "Mutation Fixture",
        rootURL: root,
        accessPolicy: ProjectAccessPolicy(
          read: .allowed,
          write: .allowed,
          network: .denied
        )
      )
    )
    return MutationFixture(
      root: root,
      projectID: summary.id,
      service: RestrictedProjectMutationService(repository: repository)
    )
  }

  private func sha256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func testCreateWritesNewFileWithRevision() async throws {
    let fixture = try await writeFixture(self)
    let result = try await fixture.service.write(
      ProjectWriteRequest(
        projectID: fixture.projectID,
        relativePath: "Sources/New.swift",
        mode: .create,
        content: "let value = 1\n",
        createParents: true
      )
    )
    XCTAssertEqual(result.relativePath, "Sources/New.swift")
    XCTAssertEqual(result.operation, "create")
    XCTAssertNil(result.oldSHA256)
    let written = try String(
      contentsOf: fixture.root.appending(path: "Sources/New.swift"), encoding: .utf8)
    XCTAssertEqual(written, "let value = 1\n")
    XCTAssertEqual(result.newSHA256, sha256(of: Data(written.utf8)))
  }

  func testCreateRefusesExistingFile() async throws {
    let fixture = try await writeFixture(self)
    try Data("existing".utf8).write(to: fixture.root.appending(path: "file.txt"))
    await assertMutationError(
      try await fixture.service.write(
        ProjectWriteRequest(
          projectID: fixture.projectID,
          relativePath: "file.txt",
          mode: .create,
          content: "new"
        )
      )
    ) { error in
      XCTAssertEqual(error, .pathExists)
    }
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appending(path: "file.txt"), encoding: .utf8),
      "existing"
    )
  }

  func testReplaceRequiresMatchingRevisionAndLeavesFileUntouchedOnConflict() async throws {
    let fixture = try await writeFixture(self)
    let path = fixture.root.appending(path: "file.txt")
    try Data("old content".utf8).write(to: path)
    let oldSHA = sha256(of: Data("old content".utf8))

    let result = try await fixture.service.write(
      ProjectWriteRequest(
        projectID: fixture.projectID,
        relativePath: "file.txt",
        mode: .replace,
        content: "new content",
        expectedSHA256: oldSHA
      )
    )
    XCTAssertEqual(result.oldSHA256, oldSHA)
    XCTAssertEqual(
      try String(contentsOf: path, encoding: .utf8),
      "new content"
    )

    try Data("newer content".utf8).write(to: path)
    await assertMutationError(
      try await fixture.service.write(
        ProjectWriteRequest(
          projectID: fixture.projectID,
          relativePath: "file.txt",
          mode: .replace,
          content: "overwritten",
          expectedSHA256: oldSHA
        )
      )
    ) { error in
      XCTAssertEqual(error, .revisionConflict)
    }
    XCTAssertEqual(
      try String(contentsOf: path, encoding: .utf8),
      "newer content"
    )
  }

  func testEditAppliesExactReplacement() async throws {
    let fixture = try await writeFixture(self)
    let path = fixture.root.appending(path: "app.swift")
    try Data("func value() { return 1 }".utf8).write(to: path)
    let oldSHA = sha256(of: Data("func value() { return 1 }".utf8))

    let result = try await fixture.service.edit(
      ProjectEditRequest(
        projectID: fixture.projectID,
        relativePath: "app.swift",
        expectedSHA256: oldSHA,
        oldText: "return 1",
        newText: "return 2"
      )
    )
    XCTAssertEqual(result.operation, "edit")
    XCTAssertEqual(
      try String(contentsOf: path, encoding: .utf8),
      "func value() { return 2 }"
    )
    XCTAssertEqual(result.boundedDiff.removedLines, ["func value() { return 1 }"])
    XCTAssertEqual(result.boundedDiff.addedLines, ["func value() { return 2 }"])
  }

  func testEditRejectsStaleSHAAndWrongReplacementCount() async throws {
    let fixture = try await writeFixture(self)
    let path = fixture.root.appending(path: "app.swift")
    try Data("x = 1\ny = 2\n".utf8).write(to: path)
    let oldSHA = sha256(of: Data("x = 1\ny = 2\n".utf8))

    await assertMutationError(
      try await fixture.service.edit(
        ProjectEditRequest(
          projectID: fixture.projectID,
          relativePath: "app.swift",
          expectedSHA256: "wrong-sha",
          oldText: "x = 1",
          newText: "x = 9"
        )
      )
    ) { error in
      XCTAssertEqual(error, .revisionConflict)
    }

    await assertMutationError(
      try await fixture.service.edit(
        ProjectEditRequest(
          projectID: fixture.projectID,
          relativePath: "app.swift",
          expectedSHA256: oldSHA,
          oldText: "=",
          newText: "!=",
          expectedReplacements: 1
        )
      )
    ) { error in
      XCTAssertEqual(error, .revisionConflict)
    }
    XCTAssertEqual(
      try String(contentsOf: path, encoding: .utf8),
      "x = 1\ny = 2\n"
    )
  }

  func testApplyPatchUpdatesAndAddsFiles() async throws {
    let fixture = try await writeFixture(self)
    try Data("line one\nline two\nline three\n".utf8).write(
      to: fixture.root.appending(path: "existing.swift")
    )
    let patch = """
      *** Begin Patch
      *** Update File: existing.swift
      @@
      -line two
      +line TWO
      *** Add File: Sources/Added.swift
      +import Foundation
      +let added = true
      *** End Patch
      """

    let results = try await fixture.service.applyPatch(
      ProjectApplyPatchRequest(
        projectID: fixture.projectID, operations: try ProjectPatchParser.parse(patch))
    )
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appending(path: "existing.swift"), encoding: .utf8),
      "line one\nline TWO\nline three\n"
    )
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appending(path: "Sources/Added.swift"), encoding: .utf8),
      "import Foundation\nlet added = true\n"
    )
  }

  func testApplyPatchRejectsAbsolutePathAndStaleRevisionWithoutModifying() async throws {
    let fixture = try await writeFixture(self)
    try Data("original\n".utf8).write(to: fixture.root.appending(path: "file.txt"))
    let stalePatch = """
      *** Begin Patch
      *** Update File: file.txt
      @@
      -original
      +changed
      *** End Patch
      """
    let staleOps = try ProjectPatchParser.parse(stalePatch)
    await assertMutationError(
      try await fixture.service.applyPatch(
        ProjectApplyPatchRequest(
          projectID: fixture.projectID,
          operations: staleOps.map {
            ProjectPatchFileOperation(
              action: $0.action,
              relativePath: $0.relativePath,
              expectedSHA256: "stale-sha",
              hunks: $0.hunks
            )
          }
        )
      )
    ) { error in
      XCTAssertEqual(error, .revisionConflict)
    }

    XCTAssertThrowsError(
      try ProjectPatchParser.parse(
        """
        *** Begin Patch
        *** Update File: /etc/passwd
        @@
        -x
        +y
        *** End Patch
        """
      )
    )
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appending(path: "file.txt"), encoding: .utf8),
      "original\n"
    )
  }

  func testDeleteFileRequiresRevision() async throws {
    let fixture = try await writeFixture(self)
    try Data("to delete".utf8).write(to: fixture.root.appending(path: "gone.txt"))
    let sha = sha256(of: Data("to delete".utf8))
    let result = try await fixture.service.managePath(
      ProjectManagePathRequest(
        projectID: fixture.projectID,
        action: .deleteFile,
        relativePath: "gone.txt",
        expectedSHA256: sha
      )
    )
    XCTAssertEqual(result.operation, "delete_file")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.root.appending(path: "gone.txt").path))

    try Data("again".utf8).write(to: fixture.root.appending(path: "gone.txt"))
    await assertMutationError(
      try await fixture.service.managePath(
        ProjectManagePathRequest(
          projectID: fixture.projectID,
          action: .deleteFile,
          relativePath: "gone.txt",
          expectedSHA256: sha
        )
      )
    ) { error in
      XCTAssertEqual(error, .revisionConflict)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fixture.root.appending(path: "gone.txt").path))
  }

  func testMoveFileRejectsExistingDestination() async throws {
    let fixture = try await writeFixture(self)
    try Data("source".utf8).write(to: fixture.root.appending(path: "source.txt"))
    try Data("dest".utf8).write(to: fixture.root.appending(path: "dest.txt"))
    let sha = sha256(of: Data("source".utf8))

    await assertMutationError(
      try await fixture.service.managePath(
        ProjectManagePathRequest(
          projectID: fixture.projectID,
          action: .moveFile,
          relativePath: "source.txt",
          destinationRelativePath: "dest.txt",
          sourceExpectedSHA256: sha,
          destinationExpectedAbsent: true
        )
      )
    ) { error in
      XCTAssertEqual(error, .pathExists)
    }

    try FileManager.default.removeItem(at: fixture.root.appending(path: "dest.txt"))
    let result = try await fixture.service.managePath(
      ProjectManagePathRequest(
        projectID: fixture.projectID,
        action: .moveFile,
        relativePath: "source.txt",
        destinationRelativePath: "dest.txt",
        sourceExpectedSHA256: sha,
        destinationExpectedAbsent: true
      )
    )
    XCTAssertEqual(result.operation, "move_file")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.root.appending(path: "source.txt").path))
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appending(path: "dest.txt"), encoding: .utf8),
      "source"
    )
  }

  func testCreateAndDeleteEmptyDirectory() async throws {
    let fixture = try await writeFixture(self)
    _ = try await fixture.service.managePath(
      ProjectManagePathRequest(
        projectID: fixture.projectID,
        action: .createDirectory,
        relativePath: "empty-dir"
      )
    )
    var isDirectory: ObjCBool = false
    let dirURL = fixture.root.appending(path: "empty-dir")
    XCTAssertTrue(FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)

    _ = try await fixture.service.managePath(
      ProjectManagePathRequest(
        projectID: fixture.projectID,
        action: .deleteEmptyDirectory,
        relativePath: "empty-dir"
      )
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: dirURL.path))

    _ = try await fixture.service.managePath(
      ProjectManagePathRequest(
        projectID: fixture.projectID,
        action: .createDirectory,
        relativePath: "empty-dir"
      )
    )
    try Data("nope".utf8).write(to: dirURL.appending(path: "child.txt"))
    await assertMutationError(
      try await fixture.service.managePath(
        ProjectManagePathRequest(
          projectID: fixture.projectID,
          action: .deleteEmptyDirectory,
          relativePath: "empty-dir"
        )
      )
    )
  }

  func testRejectsSensitivePathsAndSymlinkEscape() async throws {
    let fixture = try await writeFixture(self)
    try FileManager.default.createDirectory(
      at: fixture.root.appending(path: "sub"), withIntermediateDirectories: true)
    let outside = fixture.root.deletingLastPathComponent().appending(path: "outside-target.txt")
    try Data("outside".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appending(path: "sub/escape.txt"),
      withDestinationURL: outside
    )

    await assertMutationError(
      try await fixture.service.write(
        ProjectWriteRequest(
          projectID: fixture.projectID,
          relativePath: ".env",
          mode: .create,
          content: "SECRET=x"
        )
      )
    ) { error in
      XCTAssertEqual(error, .forbiddenPath)
    }
    await assertMutationError(
      try await fixture.service.write(
        ProjectWriteRequest(
          projectID: fixture.projectID,
          relativePath: "sub/escape.txt",
          mode: .replace,
          content: "evil"
        )
      )
    )
    XCTAssertEqual(
      try String(contentsOf: outside, encoding: .utf8),
      "outside"
    )
  }

  func testRejectsHardLinkedTarget() async throws {
    let fixture = try await writeFixture(self)
    try Data("hard".utf8).write(to: fixture.root.appending(path: "a.txt"))
    try FileManager.default.linkItem(
      at: fixture.root.appending(path: "a.txt"),
      to: fixture.root.appending(path: "b.txt")
    )
    let sha = sha256(of: Data("hard".utf8))
    await assertMutationError(
      try await fixture.service.write(
        ProjectWriteRequest(
          projectID: fixture.projectID,
          relativePath: "a.txt",
          mode: .replace,
          content: "new",
          expectedSHA256: sha
        )
      )
    ) { error in
      XCTAssertEqual(error, .unsupportedHardLink)
    }
  }

  func testChangesReportsGitStatusAndDiff() async throws {
    let fixture = try await writeFixture(self)
    try runGit(["init", "-q", "-b", "main"], at: fixture.root)
    try Data("one\n".utf8).write(to: fixture.root.appending(path: "tracked.txt"))
    try runGit(["add", "--", "tracked.txt"], at: fixture.root)
    try runGit(["commit", "-q", "-m", "init"], at: fixture.root)
    try Data("one\ntwo\n".utf8).write(to: fixture.root.appending(path: "tracked.txt"))
    try Data("new\n".utf8).write(to: fixture.root.appending(path: "untracked.txt"))

    let changes = try await fixture.service.changes(projectID: fixture.projectID)
    XCTAssertTrue(changes.changedFiles.contains { $0.contains("tracked.txt") })
    XCTAssertTrue(changes.changedFiles.contains { $0.contains("untracked.txt") })
    XCTAssertTrue(changes.diff.contains("+two"))
    XCTAssertEqual(changes.additions, 1)
    XCTAssertFalse(changes.notGitRepository)
  }

  func testChangesReportsNonGitRepository() async throws {
    let fixture = try await writeFixture(self)
    let changes = try await fixture.service.changes(projectID: fixture.projectID)
    XCTAssertTrue(changes.notGitRepository)
    XCTAssertTrue(changes.changedFiles.isEmpty)
  }
}

private struct MutationFixture {
  let root: URL
  let projectID: ProjectID
  let service: RestrictedProjectMutationService
}

private func assertMutationError<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (ProjectMutationError) -> Void = { _ in },
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch let error as ProjectMutationError {
    errorHandler(error)
  } catch {
    XCTFail("Unexpected error type: \(error)", file: file, line: line)
  }
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
