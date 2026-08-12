import Foundation
import XCTest

@testable import BridgeGit

final class GitEvidenceCollectorTests: XCTestCase {
  func testCleanBaselineAndFinalEvidenceComeFromRealRepository() async throws {
    let root = try makeScratchDirectory(label: "evidence")
    defer { removeScratchDirectory(root) }
    try initializeRepository(at: root)
    let store = GitPatchStore(maximumPageBytes: 32)
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": root]),
      patchStore: store
    )

    let baseline = try await collector.captureBaseline(projectIdentifier: "project")
    XCTAssertEqual(baseline.status.repositoryClassification, .gitWorkingTree)
    XCTAssertFalse(baseline.status.isDirty)
    XCTAssertNotNil(baseline.status.branch)
    XCTAssertEqual(baseline.status.headCommit?.count, 40)
    XCTAssertEqual(baseline.changeAttribution, .attributableFromCleanBaseline)

    try Data("initial\nchanged\n".utf8).write(to: root.appending(path: "tracked.txt"))
    try Data("untracked\n".utf8).write(to: root.appending(path: "new file.txt"))
    let final = try await collector.captureFinal(
      projectIdentifier: "project",
      baseline: baseline
    )

    XCTAssertEqual(final.changedFiles, ["new file.txt", "tracked.txt"])
    XCTAssertEqual(final.untrackedFiles, ["new file.txt"])
    XCTAssertTrue(final.diffStat.contains("tracked.txt"))
    XCTAssertEqual(final.changeAttribution, .attributableFromCleanBaseline)
    let handle = try XCTUnwrap(final.patch)
    let patch = try await readEntirePatch(handle, from: store, pageBytes: 13)
    XCTAssertTrue(String(decoding: patch, as: UTF8.self).contains("+changed"))
    XCTAssertFalse(String(decoding: patch, as: UTF8.self).contains("untracked"))
  }

  func testDirtyBaselineDeclaresMixedAttributionRisk() async throws {
    let root = try makeScratchDirectory(label: "dirty")
    defer { removeScratchDirectory(root) }
    try initializeRepository(at: root)
    try Data("initial\nuser edit\n".utf8).write(to: root.appending(path: "tracked.txt"))
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": root])
    )

    let baseline = try await collector.captureBaseline(projectIdentifier: "project")
    XCTAssertTrue(baseline.status.isDirty)
    XCTAssertEqual(baseline.changeAttribution, .mixedWithPreexistingChanges)

    try Data("task edit\n".utf8).write(to: root.appending(path: "task.txt"))
    let final = try await collector.captureFinal(
      projectIdentifier: "project",
      baseline: baseline
    )
    XCTAssertEqual(final.changeAttribution, .mixedWithPreexistingChanges)
    XCTAssertEqual(final.changedFiles, ["task.txt", "tracked.txt"])
  }

  func testNonGitDirectoryHasStructuredEvidence() async throws {
    let root = try makeScratchDirectory(label: "non-git")
    defer { removeScratchDirectory(root) }
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": root])
    )

    let baseline = try await collector.captureBaseline(projectIdentifier: "project")
    let final = try await collector.captureFinal(
      projectIdentifier: "project",
      baseline: baseline
    )

    XCTAssertEqual(baseline.status, .notGitRepository)
    XCTAssertEqual(baseline.changeAttribution, .unavailableForNonGitProject)
    XCTAssertEqual(final.status, .notGitRepository)
    XCTAssertTrue(final.diffStat.isEmpty)
    XCTAssertNil(final.patch)
    XCTAssertEqual(final.changeAttribution, .unavailableForNonGitProject)
  }

  func testRegisteredRootMustBeCanonicalAndRepositoryTopLevel() async throws {
    let root = try makeScratchDirectory(label: "root-boundary")
    defer { removeScratchDirectory(root) }
    try initializeRepository(at: root)
    let nested = root.appending(path: "nested", directoryHint: .isDirectory)
    let alias = root.deletingLastPathComponent().appending(
      path: "bridge-git-alias-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    defer { try? FileManager.default.removeItem(at: alias) }

    let nestedCollector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": nested])
    )
    await assertGitEvidenceError(.repositoryRootMismatch) {
      _ = try await nestedCollector.captureBaseline(projectIdentifier: "project")
    }

    let aliasCollector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": alias])
    )
    await assertGitEvidenceError(.invalidAuthorizedRoot) {
      _ = try await aliasCollector.captureBaseline(projectIdentifier: "project")
    }
  }

  func testPathsAndProjectIdentifierCannotInjectGitArgumentsOrShell() async throws {
    let parent = try makeScratchDirectory(label: "injection-parent")
    defer { removeScratchDirectory(parent) }
    let root = parent.appending(
      path: "repo; touch SHOULD_NOT_EXIST",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try initializeRepository(at: root)
    let suspiciousFile = "--upload-pack=touch SHOULD_NOT_EXIST"
    try Data("safe\n".utf8).write(to: root.appending(path: suspiciousFile))
    let projectIdentifier = "$(touch SHOULD_NOT_EXIST)"
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: [projectIdentifier: root])
    )

    let baseline = try await collector.captureBaseline(projectIdentifier: projectIdentifier)

    XCTAssertEqual(baseline.status.entries.map(\.path), [suspiciousFile])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appending(path: "SHOULD_NOT_EXIST").path
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: parent.appending(path: "SHOULD_NOT_EXIST").path)
    )
  }

  func testFileAndStatusByteLimitsFailClosed() async throws {
    let root = try makeScratchDirectory(label: "limits")
    defer { removeScratchDirectory(root) }
    try initializeRepository(at: root)
    for name in ["one.txt", "two.txt", "three.txt"] {
      try Data(name.utf8).write(to: root.appending(path: name))
    }
    let authorizer = FixedGitRootAuthorizer(roots: ["project": root])
    let fileLimited = GitEvidenceCollector(
      rootAuthorizer: authorizer,
      limits: GitEvidenceLimits(maximumFileCount: 2)
    )
    await assertGitEvidenceError(.fileCountLimitExceeded) {
      _ = try await fileLimited.captureBaseline(projectIdentifier: "project")
    }

    let byteLimited = GitEvidenceCollector(
      rootAuthorizer: authorizer,
      limits: GitEvidenceLimits(maximumStatusBytes: 32)
    )
    await assertGitEvidenceError(.commandOutputLimitExceeded) {
      _ = try await byteLimited.captureBaseline(projectIdentifier: "project")
    }
  }

  func testRepositoryControlledFilterIsRejectedWithoutExecution() async throws {
    let root = try makeScratchDirectory(label: "malicious-filter")
    defer { removeScratchDirectory(root) }
    try initializeRepository(at: root)
    let marker = root.appending(path: "FILTER_EXECUTED")
    try Data("*.txt filter=malicious\n".utf8).write(
      to: root.appending(path: ".gitattributes")
    )
    try runTestGit(
      ["config", "filter.malicious.clean", "touch FILTER_EXECUTED"],
      at: root
    )
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": root])
    )

    await assertGitEvidenceError(.unsafeRepositoryConfiguration) {
      _ = try await collector.captureBaseline(projectIdentifier: "project")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testFilterAttributeWithoutDriverConfigurationIsStillRejected() async throws {
    let root = try makeScratchDirectory(label: "filter-attribute")
    defer { removeScratchDirectory(root) }
    try initializeRepository(at: root)
    try Data("*.txt filter=not-configured\n".utf8).write(
      to: root.appending(path: ".gitattributes")
    )
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": root])
    )

    await assertGitEvidenceError(.unsafeGitAttributes) {
      _ = try await collector.captureBaseline(projectIdentifier: "project")
    }
  }

  func testRepositoryAliasCannotOverrideFixedBuiltinCommands() async throws {
    let root = try makeScratchDirectory(label: "alias")
    defer { removeScratchDirectory(root) }
    try initializeRepository(at: root)
    let marker = root.appending(path: "ALIAS_EXECUTED")
    try runTestGit(["config", "alias.status", "!touch ALIAS_EXECUTED"], at: root)
    try runTestGit(["config", "alias.diff", "!touch ALIAS_EXECUTED"], at: root)
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": root])
    )

    let baseline = try await collector.captureBaseline(projectIdentifier: "project")

    XCTAssertEqual(baseline.status.repositoryClassification, .gitWorkingTree)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testRepositoryFsmonitorCommandIsRejectedWithoutExecution() async throws {
    let root = try makeScratchDirectory(label: "fsmonitor")
    defer { removeScratchDirectory(root) }
    try initializeRepository(at: root)
    let marker = root.appending(path: "FSMONITOR_EXECUTED")
    try runTestGit(["config", "core.fsmonitor", "touch FSMONITOR_EXECUTED"], at: root)
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": root])
    )

    await assertGitEvidenceError(.unsafeRepositoryConfiguration) {
      _ = try await collector.captureBaseline(projectIdentifier: "project")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testPatchStorageIsBoundedAndPagesCannotBypassPageLimit() async throws {
    let root = try makeScratchDirectory(label: "patch-limit")
    defer { removeScratchDirectory(root) }
    try initializeRepository(at: root)
    let limits = GitEvidenceLimits(maximumPatchBytes: 128, maximumPatchPageBytes: 17)
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["project": root]),
      limits: limits
    )
    let baseline = try await collector.captureBaseline(projectIdentifier: "project")
    try Data(("initial\n" + String(repeating: "content", count: 300)).utf8).write(
      to: root.appending(path: "tracked.txt")
    )

    let final = try await collector.captureFinal(
      projectIdentifier: "project",
      baseline: baseline
    )
    let handle = try XCTUnwrap(final.patch)
    XCTAssertEqual(handle.totalBytes, 128)
    XCTAssertTrue(handle.isTruncated)
    let page = try await collector.patchStore.page(
      for: handle,
      maximumBytes: Int.max
    )
    XCTAssertEqual(page.bytes.count, 17)
    XCTAssertEqual(page.nextOffset, 17)
    XCTAssertTrue(page.isTruncated)
  }

  func testBaselineCannotBeReusedForAnotherProject() async throws {
    let first = try makeScratchDirectory(label: "first")
    let second = try makeScratchDirectory(label: "second")
    defer {
      removeScratchDirectory(first)
      removeScratchDirectory(second)
    }
    try initializeRepository(at: first)
    try initializeRepository(at: second)
    let collector = GitEvidenceCollector(
      rootAuthorizer: FixedGitRootAuthorizer(roots: ["first": first, "second": second])
    )
    let baseline = try await collector.captureBaseline(projectIdentifier: "first")

    await assertGitEvidenceError(.baselineProjectMismatch) {
      _ = try await collector.captureFinal(projectIdentifier: "second", baseline: baseline)
    }
  }

  private func readEntirePatch(
    _ handle: GitPatchHandle,
    from store: GitPatchStore,
    pageBytes: Int
  ) async throws -> Data {
    var result = Data()
    var offset = 0
    while true {
      let page = try await store.page(
        for: handle,
        offset: offset,
        maximumBytes: pageBytes
      )
      XCTAssertLessThanOrEqual(page.bytes.count, pageBytes)
      result.append(page.bytes)
      guard let nextOffset = page.nextOffset else { return result }
      offset = nextOffset
    }
  }
}
