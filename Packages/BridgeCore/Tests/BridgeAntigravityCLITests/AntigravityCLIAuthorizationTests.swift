import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIAuthorizationTests: XCTestCase {
  func testAutoApprovedNetworkTaskUsesAntigravityNativeSandbox() throws {
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
    let launch = try AntigravityCLILaunchBuilder().make(
      installation: try installation(),
      request: request,
      runDirectory: runDirectory,
      sourceEnvironment: ["HOME": projectRoot]
    )

    XCTAssertTrue(launch.process.argv.contains("--dangerously-skip-permissions"))
    XCTAssertTrue(launch.process.argv.contains("--sandbox"))
    XCTAssertEqual(launch.process.argv.first, launch.resolvedExecutablePath)
    XCTAssertFalse(launch.process.argv.contains("sandbox-exec"))
    let modeIndex = try XCTUnwrap(launch.process.argv.firstIndex(of: "--mode"))
    XCTAssertEqual(
      Array(launch.process.argv[modeIndex...].prefix(2)),
      ["--mode", "plan"]
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
