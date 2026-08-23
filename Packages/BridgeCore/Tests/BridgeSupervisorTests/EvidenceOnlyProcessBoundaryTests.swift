import BridgeCodexRPC
import Foundation
import XCTest

@testable import BridgeSupervisor

final class EvidenceOnlyProcessBoundaryTests: XCTestCase {
  func testWrappedProcessCannotReadProjectOrUserDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-evidence-boundary-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let home = directory.appending(path: "home", directoryHint: .isDirectory)
    let project = directory.appending(path: "project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("project-secret".utf8).write(to: project.appendingPathComponent("secret.txt"))
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let script = """
      test ! -r \"\(project.path)/secret.txt\" || exit 41
      test ! -r \"/Users/\(NSUserName())/.zprofile\" || exit 42
      test ! -w \"\(project.path)\" || exit 43
      test ! -w \"/Users/\(NSUserName())/.zprofile\" || exit 44
      exit 0
      """
    let configuration = try EvidenceOnlyProcessBoundary.configuration(
      wrapping: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
      ),
      isolatedHomeURL: home,
      deniedReadRoots: [project]
    )
    let process = Process()
    process.executableURL = configuration.executableURL
    process.arguments = configuration.arguments
    process.currentDirectoryURL = configuration.currentDirectoryURL
    process.environment = configuration.environment
    try process.run()
    process.waitUntilExit()

    XCTAssertEqual(process.terminationStatus, 0)
  }

  func testWrappedProcessDeniesARealUsersPathOutsideIsolatedHome() throws {
    let userHome = FileManager.default.homeDirectoryForCurrentUser
    let directory = userHome.appending(
      path: "Library/Caches/bridge-evidence-boundary-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let home = directory.appending(path: "home", directoryHint: .isDirectory)
    let sentinel = directory.appendingPathComponent("user-secret.txt")
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try Data("user-secret".utf8).write(to: sentinel, options: .atomic)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    let script = "test ! -r \"\(sentinel.path)\" && test ! -w \"\(sentinel.path)\""
    let configuration = try EvidenceOnlyProcessBoundary.configuration(
      wrapping: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
      ),
      isolatedHomeURL: home,
      deniedReadRoots: []
    )
    let process = Process()
    process.executableURL = configuration.executableURL
    process.arguments = configuration.arguments
    process.currentDirectoryURL = configuration.currentDirectoryURL
    process.environment = configuration.environment
    try process.run()
    process.waitUntilExit()

    XCTAssertEqual(process.terminationStatus, 0)
  }

  func testRejectsProfilePathInjection() {
    XCTAssertThrowsError(
      try EvidenceOnlyProcessBoundary.configuration(
        wrapping: AppServerConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: []),
        isolatedHomeURL: URL(fileURLWithPath: "/tmp/bridge\"home"),
        deniedReadRoots: []
      )
    ) { error in
      XCTAssertEqual(
        error as? EvidenceOnlyProcessBoundaryError,
        .invalidPath("isolatedHome")
      )
    }
  }

  func testProfileDeniesNetworkAccess() throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "bridge-evidence-home-(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: home) }

    let configuration = try EvidenceOnlyProcessBoundary.configuration(
      wrapping: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: []
      ),
      isolatedHomeURL: home,
      deniedReadRoots: []
    )
    let profile = configuration.arguments[1]
    XCTAssertTrue(profile.contains("(deny network*)"))
    XCTAssertFalse(profile.contains("(allow network*)"))
  }

  func testAuthenticationProfileAllowsOutboundOnly() throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "bridge-evidence-auth-home-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: home,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: home) }

    let configuration = try EvidenceOnlyProcessBoundary.configuration(
      wrapping: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: []
      ),
      isolatedHomeURL: home,
      deniedReadRoots: [],
      networkAccess: true
    )
    let profile = configuration.arguments[1]
    XCTAssertTrue(profile.contains("(allow network-outbound)"))
    XCTAssertFalse(profile.contains("(allow network*)"))
    XCTAssertFalse(profile.contains("(allow network-inbound)"))
  }

  func testSessionCleanupDoesNotFollowReplacedRootSymlink() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-evidence-cleanup-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let root = directory.appending(path: "root", directoryHint: .isDirectory)
    let replacement = directory.appending(
      path: "replacement",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try FileManager.default.createDirectory(
      at: replacement,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let sessionName = "session-\(UUID().uuidString.lowercased())"
    let session = root.appendingPathComponent(sessionName, isDirectory: true)
    try FileManager.default.createDirectory(
      at: session,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try FileManager.default.removeItem(at: root)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: replacement)
    let replacementSession = replacement.appendingPathComponent(sessionName, isDirectory: true)
    try FileManager.default.createDirectory(
      at: replacementSession,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

    EvidenceOnlyProcessBoundary.removeSessionHome(session, from: root)

    XCTAssertTrue(FileManager.default.fileExists(atPath: replacementSession.path))
  }
}
