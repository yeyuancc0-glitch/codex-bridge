import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import XCTest

@testable import BridgeCodexService

final class AgentTaskBriefApprovalTests: XCTestCase {
  func testOnlyFullAccessNetworkTasksAutoApproveProviderTools() {
    XCTAssertEqual(
      makeBrief(accessMode: .fullAccess, networkAllowed: true).toolApprovalPolicy,
      .autoApprove
    )
    XCTAssertEqual(
      makeBrief(accessMode: .fullAccess, networkAllowed: false).toolApprovalPolicy,
      .providerManaged
    )
    XCTAssertEqual(
      makeBrief(accessMode: .requestApproval, networkAllowed: true).toolApprovalPolicy,
      .providerManaged
    )
    XCTAssertEqual(
      makeBrief(accessMode: .autoReview, networkAllowed: true).toolApprovalPolicy,
      .providerManaged
    )
  }

  private func makeBrief(
    accessMode: ServiceAccessMode,
    networkAllowed: Bool
  ) -> AgentTaskBrief {
    AgentTaskBrief(
      taskID: TaskID(rawValue: "task-agent-approval"),
      providerID: .antigravity,
      installationID: AgentInstallationID(rawValue: "installation-agent-approval"),
      projectID: ProjectID(rawValue: "project-agent-approval"),
      projectRoot: "/tmp",
      prompt: "Inspect the project.",
      networkAllowed: networkAllowed,
      accessMode: accessMode
    )
  }
}
