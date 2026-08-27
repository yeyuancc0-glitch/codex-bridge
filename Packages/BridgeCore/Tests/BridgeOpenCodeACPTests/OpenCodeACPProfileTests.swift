import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeOpenCodeACP

final class OpenCodeACPProfileTests: XCTestCase {
  func testSemanticVersionAndCompatibilityRange() {
    XCTAssertEqual(
      OpenCodeACPSemanticVersion("1.18.22"),
      OpenCodeACPSemanticVersion(major: 1, minor: 18, patch: 22)
    )
    XCTAssertEqual(
      OpenCodeACPSemanticVersion("1.18.23-beta.1+build"),
      OpenCodeACPSemanticVersion(major: 1, minor: 18, patch: 23)
    )
    XCTAssertNil(OpenCodeACPSemanticVersion("1.18"))
    XCTAssertNil(OpenCodeACPSemanticVersion("latest"))

    let compatibility = OpenCodeACPCompatibility()
    XCTAssertFalse(compatibility.accepts(version: "1.18.19"))
    XCTAssertTrue(compatibility.accepts(version: "1.18.20"))
    XCTAssertTrue(compatibility.accepts(version: "1.18.22"))
    XCTAssertTrue(compatibility.accepts(version: "1.18.99"))
    XCTAssertFalse(compatibility.accepts(version: "1.19.0"))
  }

  func testLaunchBuilderUsesNativeACPAndKeepsNativePermissionSettings() throws {
    let root = try makeTemporaryDirectory(prefix: "project")
    let runtime = temporaryPath(prefix: "runtime")
    let sourceHome = try makeTemporaryDirectory(prefix: "source-home")
    let dataHome = try makeTemporaryDirectory(prefix: "source-data")
    addTeardownBlock {
      for path in [root, runtime, sourceHome, dataHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "opencode-test"),
      providerID: .openCode,
      executablePath: "/bin/echo"
    )
    let launch = try OpenCodeACPLaunchBuilder().make(
      installation: installation,
      projectRoot: root,
      runDirectory: runtime,
      networkAllowed: false,
      sourceEnvironment: [
        "HOME": sourceHome,
        "XDG_DATA_HOME": dataHome,
        "USER": "bridge-test",
        "LANG": "en_US.UTF-8",
        "UNRELATED_SETTING": "not-forwarded",
        "OPENCODE_PERMISSION": "caller-value",
        "OPENCODE_DISABLE_PROJECT_CONFIG": "caller-value",
      ]
    )

    XCTAssertEqual(launch.process.argv, ["/bin/echo", "acp", "--cwd", root])
    XCTAssertFalse(launch.process.argv.contains("sandbox-exec"))
    XCTAssertFalse(launch.process.argv.contains("--pure"))
    XCTAssertEqual(launch.process.workingDirectory, root)
    XCTAssertEqual(launch.runDirectory, runtime)
    XCTAssertEqual(launch.process.environment["USER"], "bridge-test")
    XCTAssertNil(launch.process.environment["UNRELATED_SETTING"])
    XCTAssertEqual(launch.process.environment["XDG_DATA_HOME"], dataHome)
    XCTAssertEqual(
      launch.process.environment["XDG_CONFIG_HOME"],
      URL(fileURLWithPath: sourceHome).appendingPathComponent(".config").path
    )
    XCTAssertTrue(launch.process.environment["HOME"]?.hasPrefix(runtime + "/") == true)
    XCTAssertFalse(
      launch.process.environment["PATH"]?.contains(sourceHome + "/.local/bin") == true
    )
    for key in [
      "OPENCODE_PERMISSION",
      "OPENCODE_DISABLE_PROJECT_CONFIG",
      "OPENCODE_DISABLE_DEFAULT_PLUGINS",
      "OPENCODE_DISABLE_LSP_DOWNLOAD",
      "OPENCODE_DISABLE_CLAUDE_CODE",
    ] {
      XCTAssertNil(launch.process.environment[key], "Native setting was overridden: \(key)")
    }
    XCTAssertEqual(
      launch.process.environment["OPENCODE_DB"],
      URL(fileURLWithPath: runtime).appendingPathComponent("opencode.db").path
    )
    XCTAssertEqual(try permissions(of: runtime), 0o700)
    XCTAssertEqual(try permissions(of: runtime + "/home"), 0o700)
    XCTAssertEqual(try permissions(of: runtime + "/cache"), 0o700)
  }

  func testPerRunDatabaseAndRuntimeDirectoriesAreIndependent() throws {
    let root = try makeTemporaryDirectory(prefix: "project")
    let sourceHome = try makeTemporaryDirectory(prefix: "source-home")
    let runtimeOne = temporaryPath(prefix: "runtime-one")
    let runtimeTwo = temporaryPath(prefix: "runtime-two")
    addTeardownBlock {
      for path in [root, sourceHome, runtimeOne, runtimeTwo] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "opencode-isolation"),
      providerID: .openCode,
      executablePath: "/bin/echo"
    )
    let first = try OpenCodeACPLaunchBuilder().make(
      installation: installation,
      projectRoot: root,
      runDirectory: runtimeOne,
      networkAllowed: false,
      sourceEnvironment: ["HOME": sourceHome]
    )
    let second = try OpenCodeACPLaunchBuilder().make(
      installation: installation,
      projectRoot: root,
      runDirectory: runtimeTwo,
      networkAllowed: true,
      sourceEnvironment: ["HOME": sourceHome]
    )

    XCTAssertNotEqual(
      first.process.environment["OPENCODE_DB"],
      second.process.environment["OPENCODE_DB"]
    )
    XCTAssertNotEqual(first.process.environment["HOME"], second.process.environment["HOME"])
    XCTAssertEqual(
      first.process.environment["XDG_CONFIG_HOME"],
      second.process.environment["XDG_CONFIG_HOME"]
    )
    XCTAssertEqual(
      first.process.environment["XDG_DATA_HOME"],
      second.process.environment["XDG_DATA_HOME"]
    )
  }

  func testPersistentDatabaseIsSharedWithoutSharingPerRunHome() throws {
    let root = try makeTemporaryDirectory(prefix: "project")
    let sourceHome = try makeTemporaryDirectory(prefix: "source-home")
    let persistentState = temporaryPath(prefix: "persistent-state")
    let runtimeOne = temporaryPath(prefix: "runtime-one")
    let runtimeTwo = temporaryPath(prefix: "runtime-two")
    addTeardownBlock {
      for path in [root, sourceHome, persistentState, runtimeOne, runtimeTwo] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "opencode-persistent"),
      providerID: .openCode,
      executablePath: "/bin/echo"
    )
    let builder = OpenCodeACPLaunchBuilder()
    let first = try builder.make(
      installation: installation,
      projectRoot: root,
      runDirectory: runtimeOne,
      persistentStateDirectory: persistentState,
      networkAllowed: false,
      sourceEnvironment: ["HOME": sourceHome]
    )
    let second = try builder.make(
      installation: installation,
      projectRoot: root,
      runDirectory: runtimeTwo,
      persistentStateDirectory: persistentState,
      networkAllowed: false,
      sourceEnvironment: ["HOME": sourceHome]
    )

    XCTAssertEqual(
      first.process.environment["OPENCODE_DB"], second.process.environment["OPENCODE_DB"])
    XCTAssertNotEqual(first.process.environment["HOME"], second.process.environment["HOME"])
    XCTAssertEqual(try permissions(of: persistentState), 0o700)
  }

  func testRejectsWorldWritableExecutable() throws {
    let root = try makeTemporaryDirectory(prefix: "unsafe-executable")
    let executable = URL(fileURLWithPath: root).appendingPathComponent("opencode").path
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: executable))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777],
      ofItemAtPath: executable
    )
    let project = try makeTemporaryDirectory(prefix: "unsafe-project")
    let runtime = temporaryPath(prefix: "unsafe-runtime")
    addTeardownBlock {
      for path in [root, project, runtime] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "unsafe-opencode"),
      providerID: .openCode,
      executablePath: executable
    )

    XCTAssertThrowsError(
      try OpenCodeACPLaunchBuilder().make(
        installation: installation,
        projectRoot: project,
        runDirectory: runtime,
        networkAllowed: false,
        sourceEnvironment: ["HOME": root]
      )
    ) { error in
      guard case .installationUnavailable? = error as? AgentRuntimeError else {
        return XCTFail("Expected an unsafe installation rejection, got \(error)")
      }
    }
  }

  private func makeTemporaryDirectory(prefix: String) throws -> String {
    let path = temporaryPath(prefix: prefix)
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return path
  }

  private func temporaryPath(prefix: String) -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true).path
  }

  private func permissions(of path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
  }
}
