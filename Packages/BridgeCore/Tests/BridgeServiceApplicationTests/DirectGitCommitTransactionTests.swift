import BridgeDirectCommand
import BridgeMCP
import Foundation
import XCTest

@testable import BridgeServiceApplication

final class DirectGitCommitTransactionTests: XCTestCase {
  func testLegacyReceiptDecodingDefaultsIndexSynchronizationToSuccess() throws {
    let data = Data(
      #"{"commit_hash":null,"changed_files":[],"summary":"clean","exit_code":0}"#.utf8
    )
    let receipt = try JSONDecoder().decode(MCPDirectGitCommitReceipt.self, from: data)
    XCTAssertTrue(receipt.indexSynchronized)
    XCTAssertNil(receipt.indexSynchronizationError)
  }

  func testExistingRealIndexLockPreventsCommitBeforeHeadChanges() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    try initializeRepository(at: fixture.root)
    try Data("baseline\n".utf8).write(to: fixture.root.appending(path: "Baseline.txt"))
    _ = try runGit(["add", "--", "Baseline.txt"], at: fixture.root)
    _ = try runGit(["commit", "-m", "test: baseline"], at: fixture.root)
    let originalHead = try runGit(["rev-parse", "HEAD"], at: fixture.root)
    try Data("pending\n".utf8).write(to: fixture.root.appending(path: "Pending.txt"))
    let lock = fixture.root.appending(path: ".git/index.lock")
    try Data().write(to: lock)
    defer { try? FileManager.default.removeItem(at: lock) }

    do {
      _ = try await BridgeServiceApplication.runGitCommit(
        project: fixture.project,
        message: "test: must not commit while index is locked",
        files: ["Pending.txt"],
        runner: DirectGitRunner()
      )
      XCTFail("Expected the existing Git index lock to reject the commit")
    } catch let error as DirectGitCommitError {
      guard case .gitFailed(let summary) = error else {
        return XCTFail("Expected gitFailed, got \(error)")
      }
      XCTAssertTrue(summary.contains("busy"))
    }
    XCTAssertEqual(try runGit(["rev-parse", "HEAD"], at: fixture.root), originalHead)
  }

  func testPostCommitWorkingTreeEditIsNotAccidentallyStaged() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    try initializeRepository(at: fixture.root)
    try Data("committed content\n".utf8).write(to: fixture.root.appending(path: "Race.txt"))
    try installPostCommitHook(
      "#!/bin/sh\nprintf 'edited after commit\\n' > Race.txt\n",
      at: fixture.root
    )

    let receipt = try await BridgeServiceApplication.runGitCommit(
      project: fixture.project,
      message: "test: preserve post-commit edit",
      files: ["Race.txt"],
      runner: DirectGitRunner()
    )

    XCTAssertTrue(receipt.indexSynchronized)
    XCTAssertNil(receipt.indexSynchronizationError)
    XCTAssertEqual(try runGit(["diff", "--cached", "--name-only"], at: fixture.root), "")
    XCTAssertEqual(try runGit(["diff", "--name-only"], at: fixture.root), "Race.txt")
    XCTAssertEqual(
      try runGit(["show", "HEAD:Race.txt"], at: fixture.root),
      "committed content"
    )
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appending(path: "Race.txt")),
      "edited after commit\n"
    )
  }

  func testIndexInstallFailureReturnsCommitHashAsPartialSuccess() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    try initializeRepository(at: fixture.root)
    try Data("committed content\n".utf8).write(to: fixture.root.appending(path: "Partial.txt"))
    try installPostCommitHook(
      "#!/bin/sh\nmkdir .git/index\n",
      at: fixture.root
    )

    let receipt = try await BridgeServiceApplication.runGitCommit(
      project: fixture.project,
      message: "test: report partial success",
      files: ["Partial.txt"],
      runner: DirectGitRunner()
    )
    try? FileManager.default.removeItem(at: fixture.root.appending(path: ".git/index"))

    XCTAssertFalse(receipt.indexSynchronized)
    XCTAssertNotNil(receipt.indexSynchronizationError)
    XCTAssertEqual(receipt.commitHash, try runGit(["rev-parse", "HEAD"], at: fixture.root))
    XCTAssertEqual(receipt.changedFiles, ["Partial.txt"])
    XCTAssertEqual(receipt.exitCode, 0)
  }

  private func initializeRepository(at root: URL) throws {
    _ = try runGit(["init"], at: root)
    _ = try runGit(["config", "user.email", "bridge@example.com"], at: root)
    _ = try runGit(["config", "user.name", "Codex Bridge"], at: root)
  }

  private func installPostCommitHook(_ script: String, at root: URL) throws {
    let hook = root.appending(path: ".git/hooks/post-commit")
    try Data(script.utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
  }

  @discardableResult
  private func runGit(_ arguments: [String], at root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "DirectGitCommitTransactionTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: text]
      )
    }
    return text
  }
}
