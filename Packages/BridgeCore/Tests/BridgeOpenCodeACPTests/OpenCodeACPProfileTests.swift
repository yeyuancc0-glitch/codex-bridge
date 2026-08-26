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

  func testLaunchBuilderProducesControlledReadOnlyEnvironmentAndSandbox() throws {
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
      ]
    )

    XCTAssertEqual(launch.process.argv[0], "/usr/bin/sandbox-exec")
    XCTAssertEqual(launch.process.argv[1], "-p")
    XCTAssertEqual(launch.process.argv[3], "--")
    XCTAssertEqual(Array(launch.process.argv.suffix(2)), ["--pure", "acp"])
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
    XCTAssertEqual(launch.process.environment["OPENCODE_AUTO_SHARE"], "false")
    XCTAssertEqual(launch.process.environment["OPENCODE_DISABLE_CLAUDE_CODE"], "1")
    XCTAssertEqual(launch.process.environment["OPENCODE_DISABLE_DEFAULT_PLUGINS"], "1")
    XCTAssertEqual(launch.process.environment["OPENCODE_DISABLE_LSP_DOWNLOAD"], "1")
    XCTAssertEqual(launch.process.environment["OPENCODE_DISABLE_PROJECT_CONFIG"], "1")
    XCTAssertEqual(launch.process.environment["OPENCODE_ENABLE_EXA"], "false")
    XCTAssertEqual(launch.process.environment["OPENCODE_EXPERIMENTAL"], "false")
    XCTAssertEqual(
      launch.process.environment["OPENCODE_DB"],
      URL(fileURLWithPath: runtime).appendingPathComponent("opencode.db").path
    )

    let permission = try XCTUnwrap(launch.process.environment["OPENCODE_PERMISSION"])
    let permissionObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(permission.utf8)) as? [String: String]
    )
    XCTAssertEqual(permissionObject["read"], "allow")
    XCTAssertEqual(permissionObject["edit"], "deny")
    XCTAssertEqual(permissionObject["bash"], "deny")
    XCTAssertEqual(permissionObject["webfetch"], "deny")
    XCTAssertEqual(permissionObject["websearch"], "deny")

    let sandbox = launch.process.argv[2]
    XCTAssertTrue(sandbox.contains("(deny file-write* "))
    XCTAssertTrue(sandbox.contains(launch.process.workingDirectory))
    XCTAssertTrue(sandbox.contains(launch.runDirectory))
    XCTAssertEqual(try permissions(of: runtime), 0o700)
    XCTAssertEqual(try permissions(of: runtime + "/home"), 0o700)
    XCTAssertEqual(try permissions(of: runtime + "/cache"), 0o700)
  }

  func testNetworkProfileOnlyEnablesExplicitWebTools() throws {
    let root = try makeTemporaryDirectory(prefix: "network-project")
    let runtime = temporaryPath(prefix: "network-runtime")
    let sourceHome = try makeTemporaryDirectory(prefix: "network-home")
    addTeardownBlock {
      for path in [root, runtime, sourceHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "opencode-network"),
      providerID: .openCode,
      executablePath: "/bin/echo"
    )
    let launch = try OpenCodeACPLaunchBuilder().make(
      installation: installation,
      projectRoot: root,
      runDirectory: runtime,
      networkAllowed: true,
      sourceEnvironment: ["HOME": sourceHome]
    )

    XCTAssertFalse(launch.process.argv[2].contains("(deny network*)"))
    let permission = try XCTUnwrap(launch.process.environment["OPENCODE_PERMISSION"])
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(permission.utf8)) as? [String: String]
    )
    XCTAssertEqual(object["webfetch"], "allow")
    XCTAssertEqual(object["websearch"], "allow")
    XCTAssertEqual(object["edit"], "deny")
    XCTAssertEqual(object["bash"], "deny")
  }

  func testSandboxAllowsRuntimeWritesAndDeniesProjectWrites() throws {
    let root = try makeTemporaryDirectory(prefix: "sandbox-project")
    let runtime = temporaryPath(prefix: "sandbox-runtime")
    let sourceHome = try makeTemporaryDirectory(prefix: "sandbox-home")
    let dataHome = try makeTemporaryDirectory(prefix: "sandbox-data")
    addTeardownBlock {
      for path in [root, runtime, sourceHome, dataHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "opencode-sandbox"),
      providerID: .openCode,
      executablePath: "/bin/echo"
    )
    let launch = try OpenCodeACPLaunchBuilder().make(
      installation: installation,
      projectRoot: root,
      runDirectory: runtime,
      networkAllowed: false,
      sourceEnvironment: ["HOME": sourceHome, "XDG_DATA_HOME": dataHome]
    )
    let profile = launch.process.argv[2]
    let allowedPath = URL(fileURLWithPath: runtime).appendingPathComponent("allowed").path
    let deniedPath = URL(fileURLWithPath: root).appendingPathComponent("denied").path

    XCTAssertEqual(try runTouch(path: allowedPath, sandboxProfile: profile), 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allowedPath))
    XCTAssertNotEqual(try runTouch(path: deniedPath, sandboxProfile: profile), 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: deniedPath))
    XCTAssertFalse(profile.contains("(subpath \"\(dataHome)\")"))
  }

  func testRejectsRuntimeDirectoryInsideProject() throws {
    let root = try makeTemporaryDirectory(prefix: "overlap-project")
    let runtime = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("runtime", isDirectory: true).path
    let sourceHome = try makeTemporaryDirectory(prefix: "overlap-home")
    addTeardownBlock {
      try? FileManager.default.removeItem(atPath: root)
      try? FileManager.default.removeItem(atPath: sourceHome)
    }

    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "opencode-overlap"),
      providerID: .openCode,
      executablePath: "/bin/echo"
    )

    XCTAssertThrowsError(
      try OpenCodeACPLaunchBuilder().make(
        installation: installation,
        projectRoot: root,
        runDirectory: runtime,
        networkAllowed: false,
        sourceEnvironment: ["HOME": sourceHome]
      )
    ) { error in
      XCTAssertEqual(
        error as? AgentRuntimeError,
        .invalidRequest("projectRoot.runtimeOverlap")
      )
    }
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

  private func runTouch(path: String, sandboxProfile: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = ["-p", sandboxProfile, "--", "/usr/bin/touch", path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}
