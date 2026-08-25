import BridgeAgentCore
import BridgeDomain
import XCTest

final class AgentCoreContractTests: XCTestCase {
  func testRejectsNonFiniteUsageCost() {
    for value in [Double.nan, Double.infinity, -Double.infinity] {
      XCTAssertThrowsError(
        try AgentUsageUpdate(
          usedTokens: 1,
          contextSize: 2,
          costAmount: value,
          currency: "USD"
        )
      ) { error in
        XCTAssertEqual(
          error as? AgentRuntimeError,
          .invalidRequest("usage.costAmount")
        )
      }
    }
  }

  func testRejectsTooManyToolLocations() throws {
    let locations = (0...128).map { "/tmp/project/file-\($0)" }

    XCTAssertThrowsError(
      try AgentToolUpdate(
        key: "tool:1",
        name: "read",
        status: .completed,
        locations: locations
      )
    ) { error in
      XCTAssertEqual(
        error as? AgentRuntimeError,
        .invalidRequest("tool.locations")
      )
    }
  }

  func testApprovalRequiresUniqueSafeRelativePathsAndOptions() throws {
    let binding = try AgentBinding(
      providerID: .openCode,
      installationID: AgentInstallationID(rawValue: "opencode-test"),
      providerSessionID: "session-1"
    )
    let option = try AgentApprovalOption(
      id: "reject",
      name: "Reject",
      kind: "reject_once"
    )

    XCTAssertThrowsError(
      try AgentApprovalRequest(
        approvalID: "approval-1",
        taskID: TaskID(rawValue: "task-1"),
        binding: binding,
        providerItemID: "tool-1",
        kind: .fileChange,
        title: "Change file",
        relativePaths: ["../outside"],
        options: [option]
      )
    ) { error in
      XCTAssertEqual(
        error as? AgentRuntimeError,
        .invalidRequest("approval.relativePaths")
      )
    }

    XCTAssertThrowsError(
      try AgentApprovalRequest(
        approvalID: "approval-2",
        taskID: TaskID(rawValue: "task-1"),
        binding: binding,
        providerItemID: "tool-1",
        kind: .tool,
        title: "Run tool",
        options: [option, option]
      )
    ) { error in
      XCTAssertEqual(
        error as? AgentRuntimeError,
        .invalidRequest("approval.options")
      )
    }
  }
}
