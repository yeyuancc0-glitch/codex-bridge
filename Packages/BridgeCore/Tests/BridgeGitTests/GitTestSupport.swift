import Foundation
import XCTest

@testable import BridgeGit

struct FixedGitRootAuthorizer: GitProjectRootAuthorizing {
  let roots: [String: URL]

  func authorizedCanonicalGitRoot(for projectIdentifier: String) async throws -> URL {
    guard let root = roots[projectIdentifier] else { throw TestGitError.unauthorized }
    return root
  }
}

enum TestGitError: Error {
  case unauthorized
  case commandFailed
}

func makeScratchDirectory(label: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "bridge-git-\(label)-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  return root
}

func removeScratchDirectory(_ root: URL) {
  let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
  let candidate = root.standardizedFileURL.path
  guard candidate.hasPrefix(temporaryRoot + "/bridge-git-") else { return }
  try? FileManager.default.removeItem(at: root)
}

func initializeRepository(at root: URL) throws {
  try runTestGit(["init", "-q"], at: root)
  try runTestGit(["config", "user.name", "Bridge Test"], at: root)
  try runTestGit(["config", "user.email", "bridge@example.invalid"], at: root)
  try Data("initial\n".utf8).write(to: root.appending(path: "tracked.txt"))
  try runTestGit(["add", "--", "tracked.txt"], at: root)
  try runTestGit(["commit", "-q", "-m", "initial"], at: root)
}

func runTestGit(_ arguments: [String], at root: URL) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = arguments
  process.currentDirectoryURL = root
  process.environment = [
    "PATH": "/usr/bin:/bin",
    "LANG": "C",
    "LC_ALL": "C",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_TERMINAL_PROMPT": "0",
  ]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw TestGitError.commandFailed }
}

func assertGitEvidenceError(
  _ expected: GitEvidenceError,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    XCTFail("Expected \(expected)")
  } catch {
    XCTAssertEqual(error as? GitEvidenceError, expected)
  }
}
