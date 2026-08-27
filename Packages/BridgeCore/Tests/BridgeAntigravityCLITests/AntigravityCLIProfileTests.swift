import BridgeAgentCore
import BridgeDomain
import BridgeProcess
import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIProfileTests: XCTestCase {
  func testSemanticVersionParsingAndCompatibilityBoundaries() {
    XCTAssertEqual(
      AntigravityCLISemanticVersion("agy 1.1.21"),
      AntigravityCLISemanticVersion(major: 1, minor: 1, patch: 21)
    )
    XCTAssertEqual(
      AntigravityCLISemanticVersion("1.1.22-beta.3 (build 7)"),
      AntigravityCLISemanticVersion(major: 1, minor: 1, patch: 22)
    )
    XCTAssertNil(AntigravityCLISemanticVersion("1.1"))
    XCTAssertNil(AntigravityCLISemanticVersion("agy latest"))

    let compatibility = AntigravityCLICompatibility()
    XCTAssertFalse(
      compatibility.accepts(AntigravityCLISemanticVersion(major: 1, minor: 1, patch: 20)))
    XCTAssertTrue(
      compatibility.accepts(AntigravityCLISemanticVersion(major: 1, minor: 1, patch: 21)))
    XCTAssertTrue(
      compatibility.accepts(AntigravityCLISemanticVersion(major: 1, minor: 1, patch: 99)))
    XCTAssertFalse(
      compatibility.accepts(AntigravityCLISemanticVersion(major: 1, minor: 2, patch: 0)))
    XCTAssertEqual(
      AntigravityCLISemanticVersion(major: 1, minor: 1, patch: 22).stringValue,
      "1.1.22"
    )
  }

  func testLaunchBuilderUsesStreamJSONAndReadOnlyProjectBoundary() throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-project")
    let home = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-home")
    let runDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("agy-runtime-\(UUID().uuidString)", isDirectory: true).path
    addTeardownBlock {
      for path in [projectRoot, home, runDirectory] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-test"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-agy-launch"),
      projectID: ProjectID(rawValue: "project-agy-launch"),
      projectRoot: projectRoot,
      prompt: "Inspect the repository.",
      requestedSessionID: "conversation-1",
      model: "gemini-test",
      effort: "high",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )

    let launch = try AntigravityCLILaunchBuilder(sandboxExecutablePath: "/bin/echo").make(
      installation: installation,
      request: request,
      runDirectory: runDirectory,
      sourceEnvironment: [
        "HOME": home,
        "USER": "bridge-test",
        "GEMINI_API_KEY": "dummy-gemini-key",
        "GOOGLE_GEMINI_BASE_URL": "https://example.test/gemini",
        "AWS_SECRET_ACCESS_KEY": "must-not-forward",
        "OPENCODE_API_KEY": "must-not-forward",
      ]
    )

    XCTAssertTrue(launch.readOnlySandboxed)
    XCTAssertEqual(launch.process.workingDirectory, projectRoot)
    XCTAssertEqual(
      launch.process.argv.first,
      "/bin/echo"
    )
    XCTAssertEqual(launch.process.argv[1], "-p")
    XCTAssertTrue(launch.process.argv[2].contains("deny file-write*"))
    XCTAssertTrue(launch.process.argv[2].contains(projectRoot))
    XCTAssertEqual(launch.process.argv[3], "--")
    XCTAssertEqual(
      Array(launch.process.argv.dropFirst(4)),
      [
        launch.resolvedExecutablePath,
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--conversation",
        "conversation-1",
        "--model",
        "gemini-test",
        "--effort",
        "high",
      ]
    )
    XCTAssertEqual(launch.process.environment["HOME"], home)
    XCTAssertEqual(launch.process.environment["USER"], "bridge-test")
    XCTAssertEqual(launch.process.environment["GEMINI_API_KEY"], "dummy-gemini-key")
    XCTAssertEqual(
      launch.process.environment["GOOGLE_GEMINI_BASE_URL"],
      "https://example.test/gemini"
    )
    XCTAssertNil(launch.process.environment["AWS_SECRET_ACCESS_KEY"])
    XCTAssertNil(launch.process.environment["OPENCODE_API_KEY"])
    XCTAssertFalse(launch.process.argv.contains("--dangerously-skip-permissions"))
  }

  func testLaunchBuilderRejectsUnsupportedEffort() throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-project")
    let runDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("agy-runtime-\(UUID().uuidString)", isDirectory: true).path
    addTeardownBlock {
      try? FileManager.default.removeItem(atPath: projectRoot)
      try? FileManager.default.removeItem(atPath: runDirectory)
    }
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-test"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-agy-effort"),
      projectID: ProjectID(rawValue: "project-agy-effort"),
      projectRoot: projectRoot,
      prompt: "Inspect",
      effort: "xhigh",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )

    XCTAssertThrowsError(
      try AntigravityCLILaunchBuilder(sandboxExecutablePath: "/bin/echo").make(
        installation: installation,
        request: request,
        runDirectory: runDirectory,
        sourceEnvironment: [:]
      )
    ) { error in
      XCTAssertEqual(error as? AgentRuntimeError, .invalidRequest("request.effort"))
    }
  }
}
