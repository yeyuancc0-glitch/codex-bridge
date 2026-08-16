import BridgeCoordinator
import BridgeDomain
import BridgeMCP
import BridgePersistence
import BridgePresentation
import XCTest

@testable import BridgeAppShell

final class DesktopPresentationProjectionTests: XCTestCase {
  func testComposerProjectionPreservesCatalogDefaultEffort() throws {
    var operatorState = DesktopOperatorState()
    operatorState.composer = .ready(
      DesktopLocalTaskComposer(
        requestID: "request",
        projectID: "project",
        threadID: nil,
        models: [
          MCPModelSummary(
            modelID: "execution",
            displayName: "Execution",
            isDefault: true,
            reasoningEfforts: ["low", "high"],
            defaultReasoningEffort: "high"
          )
        ],
        isSubmitting: false,
        submittedDraft: nil
      )
    )

    let snapshot = DesktopPresentationProjection.snapshot(
      projects: [],
      tasks: [],
      diagnostics: [],
      operatorState: operatorState
    )

    guard case .ready(let page) = snapshot.tasks,
      case .ready(let composer)? = page.readOnlyComposer,
      let model = composer.executionModels.first
    else {
      return XCTFail("Expected a projected model composer")
    }
    XCTAssertEqual(model.defaultReasoningEffort, "high")
    XCTAssertEqual(model.preferredEffort, "high")
  }

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
    guard case .ready(let taskPage) = snapshot.tasks else {
      return XCTFail("Expected task projection")
    }
    XCTAssertEqual(taskPage.details.first?.supervisorStatus, .blocked)
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

  func testUnknownTaskOffersOnlyExplicitSuspensionRecovery() throws {
    var aggregate = TaskAggregate(
      id: TaskID(rawValue: "task-recovery"),
      submission: submission()
    )
    aggregate = try TaskReducer.reduce(aggregate, event: .preparationStarted)
    aggregate = try TaskReducer.reduce(
      aggregate,
      event: .turnStarted(
        ExecutionBinding(
          threadID: ThreadID(rawValue: "thread-recovery"),
          turnID: TurnID(rawValue: "turn-recovery"),
          turnGeneration: 1
        )
      )
    )
    aggregate = try TaskReducer.reduce(aggregate, event: .recoveryStarted)
    aggregate = try TaskReducer.reduce(aggregate, event: .recoveryAmbiguous)
    let projection = TaskProjection(aggregate: aggregate, lastSequence: 4)

    let snapshot = DesktopPresentationProjection.snapshot(
      projects: [],
      tasks: [(projection, [])],
      diagnostics: []
    )

    guard case .ready(let page) = snapshot.tasks, let detail = page.details.first else {
      return XCTFail("Expected unknown task detail")
    }
    XCTAssertEqual(detail.status, .degraded)
    XCTAssertNotNil(detail.recoveryMessage)
    XCTAssertTrue(detail.canSuspendAmbiguousRecovery)
    XCTAssertFalse(detail.canInterrupt)
  }

  func testTaskStartedAtUsesPersistedTurnStartedEvent() throws {
    let taskID = TaskID(rawValue: "task-started-at")
    var aggregate = TaskAggregate(id: taskID, submission: submission())
    aggregate = try TaskReducer.reduce(aggregate, event: .preparationStarted)
    aggregate = try TaskReducer.reduce(
      aggregate,
      event: .turnStarted(
        ExecutionBinding(
          threadID: ThreadID(rawValue: "thread-started-at"),
          turnID: TurnID(rawValue: "turn-started-at"),
          turnGeneration: 1
        )
      )
    )
    let startedAt = Date(timeIntervalSince1970: 42)
    let event = TaskEventEnvelope(
      taskID: taskID,
      sequence: 2,
      schemaVersion: 1,
      source: "bridge.coordinator",
      kind: "task.turnStarted",
      severity: "info",
      payload: Data("{}".utf8),
      createdAt: startedAt
    )

    let snapshot = DesktopPresentationProjection.snapshot(
      projects: [],
      tasks: [(TaskProjection(aggregate: aggregate, lastSequence: 2), [event])],
      diagnostics: []
    )

    guard case .ready(let page) = snapshot.tasks, let detail = page.details.first else {
      return XCTFail("Expected task detail")
    }
    XCTAssertEqual(detail.startedAt, startedAt)
  }

  func testSettingsRetentionSummaryUsesPersistedPolicyValues() {
    let policy = RetentionPolicyPresentation(
      eventDays: 14,
      metadataDays: 45,
      recentTaskLimit: 20,
      revision: 7
    )
    let snapshot = DesktopPresentationProjection.snapshot(
      projects: [],
      tasks: [],
      diagnostics: [],
      retentionPolicy: policy
    )

    guard case .ready(let settings) = snapshot.settings else {
      return XCTFail("Expected settings projection")
    }
    XCTAssertEqual(settings.retentionSummary, "事件 14 天；元数据 45 天")
    XCTAssertEqual(settings.retentionPolicy, policy)
  }

  func testSettingsProjectsPersistedReceivingPauseAsAnEnabledToggle() {
    let snapshot = DesktopPresentationProjection.snapshot(
      projects: [],
      tasks: [],
      diagnostics: [],
      lifecyclePreferences: LifecyclePreferences(
        notificationsEnabled: false,
        idleSleepEnabled: true,
        receivingPaused: true
      )
    )

    guard case .ready(let settings) = snapshot.settings,
      let receiving = settings.security.first(where: { $0.id == "receiving-paused" })
    else {
      return XCTFail("Expected receiving pause setting")
    }
    XCTAssertTrue(receiving.isOn)
    XCTAssertTrue(receiving.isEnabled)
    XCTAssertEqual(receiving.title, "暂停接收新任务")
  }

  func testPausedReceivingIsVisibleAndStillAllowsLocalConnectionTesting() {
    let snapshot = DesktopPresentationProjection.snapshot(
      projects: [],
      tasks: [],
      diagnostics: [],
      connection: DesktopTransportHealth(
        lifecycle: .ready,
        acceptsRemoteSubmissions: true,
        endpointDescription: "Manual HTTPS",
        localMCPURL: URL(string: "http://127.0.0.1:43210/mcp")!,
        actionRequired: false
      ),
      receivingPaused: true
    )

    guard case .ready(let overview) = snapshot.overview,
      case .ready(let connections) = snapshot.connections
    else {
      return XCTFail("Expected ready overview and connection pages")
    }
    XCTAssertTrue(connections.receivingPaused)
    XCTAssertTrue(connections.canChangeReceiving)
    XCTAssertEqual(overview.connectionPath.last?.status, .paused)
    XCTAssertEqual(overview.attentionItems.first?.status, .paused)
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
