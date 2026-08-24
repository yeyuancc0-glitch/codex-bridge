import BridgeDirectCommand
import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import Foundation
import XCTest

@testable import BridgeServiceApplication

final class WindowsDirectGitCommitTests: XCTestCase {
  func testCommitSynchronizesRealIndex() async throws {
    let fixture = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("committed on Windows\n".utf8).write(
      to: fixture.root.appendingPathComponent("Windows.txt")
    )

    let receipt = try await BridgeServiceApplication.runGitCommit(
      project: fixture.project,
      message: "test: native Windows transaction",
      files: ["Windows.txt"],
      runner: fixture.runner
    )

    XCTAssertTrue(receipt.indexSynchronized)
    XCTAssertEqual(receipt.changedFiles, ["Windows.txt"])
    XCTAssertEqual(try await git(["diff", "--cached", "--name-only"], fixture: fixture), "")
    XCTAssertEqual(
      try await git(["show", "HEAD:Windows.txt"], fixture: fixture),
      "committed on Windows"
    )
  }

  func testExistingIndexLockPreventsCommit() async throws {
    let fixture = try await makeRepository()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("pending\n".utf8).write(to: fixture.root.appendingPathComponent("Pending.txt"))
    let lock = fixture.root.appendingPathComponent(".git/index.lock")
    try Data().write(to: lock)

    do {
      _ = try await BridgeServiceApplication.runGitCommit(
        project: fixture.project,
        message: "test: must stay locked",
        files: ["Pending.txt"],
        runner: fixture.runner
      )
      XCTFail("Expected the existing index lock to reject the commit")
    } catch DirectGitCommitError.gitFailed(let summary) {
      XCTAssertTrue(summary.contains("busy"))
    }
    XCTAssertEqual(try await git(["rev-list", "--count", "HEAD"], fixture: fixture), "1")
  }

  private struct Fixture {
    let root: URL
    let project: ServiceProjectRecord
    let runner: DirectGitRunner
    let git: String
  }

  private func makeRepository() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-bridge-windows-git-\(Foundation.UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let runner = DirectGitRunner()
    let gitPath = try DirectGitRunner.resolveGitPath()
    let now = Date()
    let project = try ServiceProjectRecord(
      id: ProjectID(rawValue: "project-windows-git"),
      name: "Windows Git",
      root: ServiceRootIdentity(capturing: root),
      accessPolicy: ProjectAccessPolicy(write: .allowed),
      createdAt: now,
      updatedAt: now
    )
    let fixture = Fixture(root: root, project: project, runner: runner, git: gitPath)
    _ = try await git(["init"], fixture: fixture)
    _ = try await git(["config", "user.email", "bridge@example.com"], fixture: fixture)
    _ = try await git(["config", "user.name", "Codex Bridge"], fixture: fixture)
    try Data("baseline\n".utf8).write(to: root.appendingPathComponent("Baseline.txt"))
    _ = try await git(["add", "--", "Baseline.txt"], fixture: fixture)
    _ = try await git(["commit", "-m", "test: baseline"], fixture: fixture)
    return fixture
  }

  private func git(_ arguments: [String], fixture: Fixture) async throws -> String {
    let result = try await fixture.runner.run(
      argv: [fixture.git, "-C", fixture.root.path] + arguments,
      workingDirectory: fixture.root.path
    )
    let output = result.output.tail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.exitCode == 0 else {
      throw DirectGitCommitError.gitFailed(output)
    }
    return output
  }
}
