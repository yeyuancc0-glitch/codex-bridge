import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIAuthorizationTests: XCTestCase {
  func testAutoApprovedNetworkTaskKeepsReadOnlySandbox() throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(
      prefix: "agy-authorized-project"
    )
    let runDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("agy-authorized-runtime-\(UUID().uuidString)").path
    addTeardownBlock {
      try? FileManager.default.removeItem(atPath: projectRoot)
      try? FileManager.default.removeItem(atPath: runDirectory)
    }
    let request = try makeRequest(
      projectRoot: projectRoot,
      networkAccessRequested: true,
      toolApprovalPolicy: .autoApprove
    )
    let launch = try AntigravityCLILaunchBuilder(sandboxExecutablePath: "/bin/echo").make(
      installation: try installation(),
      request: request,
      runDirectory: runDirectory,
      sourceEnvironment: ["HOME": projectRoot]
    )

    XCTAssertTrue(launch.process.argv.contains("--dangerously-skip-permissions"))
    XCTAssertTrue(launch.process.argv.contains("--sandbox"))
    let providerArgv = Array(launch.process.argv.dropFirst(4))
    let modeIndex = try XCTUnwrap(providerArgv.firstIndex(of: "--mode"))
    XCTAssertEqual(
      Array(providerArgv[modeIndex...].prefix(2)),
      ["--mode", "plan"]
    )
    XCTAssertTrue(launch.readOnlySandboxed)
    XCTAssertTrue(launch.process.argv[2].contains("deny file-write*"))
    XCTAssertFalse(
      launch.process.argv[2].contains("(allow file-write* (subpath \"\(projectRoot)\"))")
    )
  }

  func testAutoApprovalRequiresExplicitNetworkGrant() throws {
    XCTAssertThrowsError(
      try makeRequest(
        projectRoot: "/tmp",
        networkAccessRequested: false,
        toolApprovalPolicy: .autoApprove
      )
    ) { error in
      XCTAssertEqual(
        error as? AgentRuntimeError,
        .invalidRequest("request.toolApprovalPolicy")
      )
    }
  }

  private func makeRequest(
    projectRoot: String,
    networkAccessRequested: Bool,
    toolApprovalPolicy: AgentToolApprovalPolicy
  ) throws -> AgentExecutionRequest {
    try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-agy-authorization"),
      projectID: ProjectID(rawValue: "project-agy-authorization"),
      projectRoot: projectRoot,
      prompt: "Read a public URL.",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: networkAccessRequested,
      toolApprovalPolicy: toolApprovalPolicy
    )
  }

  private func installation() throws -> AgentInstallation {
    try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-authorization"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )
  }
}
