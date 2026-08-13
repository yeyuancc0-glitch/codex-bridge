import BridgeCoordinator
import BridgeDomain
import BridgePresentation
import XCTest

@testable import BridgeAppShell

final class DesktopPresentationProjectionTests: XCTestCase {
  func testCodexApprovalWithoutOperationEvidenceIsDenyOnly() throws {
    let taskID = TaskID(rawValue: "task-approval")
    let approvalID = ApprovalID(rawValue: "approval-1")
    var aggregate = TaskAggregate(id: taskID, submission: submission())
    aggregate = try TaskReducer.reduce(aggregate, event: .preparationStarted)
    aggregate = try TaskReducer.reduce(
      aggregate,
      event: .turnStarted(
        ExecutionBinding(
          threadID: ThreadID(rawValue: "thread-1"),
          turnID: TurnID(rawValue: "turn-1"),
          turnGeneration: 1
        )
      )
    )
    aggregate = try TaskReducer.reduce(
      aggregate,
      event: .codexApprovalRequested(approvalID)
    )
    let projection = TaskProjection(aggregate: aggregate, lastSequence: 3)
    let tasks: [(TaskProjection, [TaskEventEnvelope])] = [(projection, [])]

    let snapshot = DesktopPresentationProjection.snapshot(
      projects: [],
      tasks: tasks,
      diagnostics: []
    )
    let sheet = DesktopPresentationProjection.pendingSheet(projects: [], tasks: tasks)

    guard case .ready(let approvals) = snapshot.approvals,
      let detail = approvals.details.first,
      case .codexApproval(let presented) = sheet
    else {
      return XCTFail("Expected a projected Codex approval")
    }
    XCTAssertEqual(detail.id, approvalID.rawValue)
    XCTAssertEqual(presented.id, approvalID.rawValue)
    XCTAssertFalse(detail.canAllow)
    XCTAssertTrue(detail.commandArguments.isEmpty)
    XCTAssertNil(detail.fileOperation)
  }

  func testCodexApprovalProjectsCorrelatedEvidenceWithoutEnablingAllow() throws {
    let taskID = TaskID(rawValue: "task-evidence")
    let approvalID = ApprovalID(rawValue: "approval-evidence")
    var aggregate = TaskAggregate(id: taskID, submission: submission())
    aggregate = try TaskReducer.reduce(aggregate, event: .preparationStarted)
    let binding = ExecutionBinding(
      threadID: ThreadID(rawValue: "thread-evidence"),
      turnID: TurnID(rawValue: "turn-evidence"),
      turnGeneration: 1
    )
    aggregate = try TaskReducer.reduce(aggregate, event: .turnStarted(binding))
    let evidence = try CodexApprovalEvidence(
      approvalID: approvalID,
      kind: .fileChange,
      authority: .correlatedFileChanges,
      threadID: binding.threadID,
      turnID: binding.turnID,
      itemID: "item-file",
      startedAtMilliseconds: 1,
      operationTitle: "Codex 文件变更审批",
      displayArguments: ["更新文件"],
      changedPaths: ["Sources/App.swift"],
      workingDirectory: ".",
      reason: "Apply the requested change.",
      evidenceDigest: String(repeating: "a", count: 64)
    )
    aggregate = try TaskReducer.reduce(
      aggregate,
      event: .codexApprovalEvidenceRecorded(evidence)
    )
    aggregate = try TaskReducer.reduce(
      aggregate,
      event: .codexApprovalRequested(approvalID)
    )
    let projection = TaskProjection(aggregate: aggregate, lastSequence: 4)
    let tasks: [(TaskProjection, [TaskEventEnvelope])] = [(projection, [])]

    let snapshot = DesktopPresentationProjection.snapshot(
      projects: [],
      tasks: tasks,
      diagnostics: []
    )
    let sheet = DesktopPresentationProjection.pendingSheet(projects: [], tasks: tasks)

    guard case .ready(let approvals) = snapshot.approvals,
      let detail = approvals.details.first,
      case .codexApproval(let presented) = sheet
    else {
      return XCTFail("Expected a projected evidence-backed approval")
    }
    XCTAssertEqual(detail.operationID, "item-file")
    XCTAssertEqual(detail.evidenceItems, ["更新文件"])
    XCTAssertEqual(detail.fileOperation, "Sources/App.swift")
    XCTAssertEqual(presented, detail)
    XCTAssertFalse(detail.canAllow)
    XCTAssertTrue(detail.commandArguments.isEmpty)
  }

  private func submission() -> TaskSubmission {
    TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "projection-approval"),
      projectID: ProjectID(rawValue: "project-1"),
      thread: .new,
      execution: ExecutionOptions(
        model: "gpt-5.6-sol",
        effort: "high",
        permissionMode: "workspace-write",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(
        enabled: true,
        model: "gpt-5.6-luna",
        effort: "medium"
      ),
      contract: TaskContract(
        goal: "Exercise the deny-only approval projection.",
        acceptanceCriteria: ["Allow remains disabled without evidence."]
      )
    )
  }
}
