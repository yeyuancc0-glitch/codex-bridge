import BridgeMCP
import XCTest

final class MCPServiceTaskWaitPolicyTests: XCTestCase {
  func testApprovalUsesFastProfile() {
    let policy = MCPServiceTaskWaitPolicy.forTask(
      status: "awaiting_local_approval",
      recentActivityAvailable: true,
      recentActivityCount: 0
    )

    XCTAssertEqual(policy.waitProfile, "fast")
    XCTAssertEqual(policy.recommendedPollAfterSeconds, 120)
    XCTAssertEqual(policy.nextAction, "await_local_approval")
    XCTAssertTrue(policy.doNotInferFailure)
    XCTAssertFalse(policy.terminal)
  }

  func testActiveAndQuietRunningUseStandardAndDeepProfiles() {
    let active = MCPServiceTaskWaitPolicy.forTask(
      status: "running",
      recentActivityAvailable: true,
      recentActivityCount: 1
    )
    XCTAssertEqual(active.waitProfile, "standard")
    XCTAssertEqual(active.recommendedPollAfterSeconds, 300)
    XCTAssertEqual(active.diagnosticAfterQuietSeconds, 1_800)

    let quiet = MCPServiceTaskWaitPolicy.forTask(
      status: "running",
      recentActivityAvailable: false,
      recentActivityCount: 0
    )
    XCTAssertEqual(quiet.waitProfile, "deep")
    XCTAssertEqual(quiet.recommendedPollAfterSeconds, 600)
    XCTAssertEqual(quiet.diagnosticAfterQuietSeconds, 3_600)
    XCTAssertTrue(quiet.doNotInferFailure)
  }

  func testTerminalPolicyStopsPollingAndPreservesStatusAuthority() {
    let completed = MCPServiceTaskWaitPolicy.forTask(
      status: "completed",
      recentActivityAvailable: true,
      recentActivityCount: 3
    )
    XCTAssertNil(completed.waitProfile)
    XCTAssertEqual(completed.recommendedPollAfterSeconds, 0)
    XCTAssertEqual(completed.nextAction, "read_final_report")
    XCTAssertTrue(completed.terminal)
    XCTAssertFalse(completed.doNotInferFailure)

    let unknown = MCPServiceTaskWaitPolicy.forTask(
      status: "unknown",
      recentActivityAvailable: true,
      recentActivityCount: 1
    )
    XCTAssertEqual(unknown.waitProfile, "deep")
    XCTAssertEqual(unknown.nextAction, "inspect_task")
    XCTAssertFalse(unknown.terminal)
    XCTAssertTrue(unknown.doNotInferFailure)
  }

  func testTaskSnapshotCarriesPolicyAndBackwardsCompatibleDecode() throws {
    let snapshot = MCPServiceTaskSnapshot(
      taskID: "tsk-running",
      projectID: "prj-demo",
      status: "running",
      recentActivity: [
        MCPServiceTaskActivity(
          sequence: 1,
          kind: "reasoning",
          summary: "Reading project files.",
          occurredAt: "2026-08-26T13:00:00Z"
        )
      ],
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-26T13:00:00Z"
    )
    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(MCPServiceTaskSnapshot.self, from: encoded)
    XCTAssertEqual(decoded.waitPolicy.waitProfile, "standard")
    XCTAssertEqual(decoded.waitPolicy.recommendedPollAfterSeconds, 300)

    let legacy = Data(
      #"{"task_id":"tsk-legacy","project_id":"prj-demo","status":"running","supervisor_status":"disabled","local_approval_required":false,"updated_at":"2026-08-26T13:00:00Z"}"#
        .utf8
    )
    let decodedLegacy = try JSONDecoder().decode(MCPServiceTaskSnapshot.self, from: legacy)
    XCTAssertEqual(decodedLegacy.waitPolicy.waitProfile, "deep")
    XCTAssertEqual(decodedLegacy.waitPolicy.recommendedPollAfterSeconds, 600)
  }
}
