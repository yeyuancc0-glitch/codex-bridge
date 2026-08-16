import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgePersistence
import BridgeReporting
import BridgeRepositories
import BridgeSupervisor
import BridgeVerification
import Foundation
import XCTest

@testable import BridgePipeline

/// Completes the "finalization recovery" acceptance criteria from
/// docs/FOLLOW_UP_PLAN.md section 8:
///   "可幂等恢复 verifying/finalization，不重复报告或释放他人锁"
///
/// Existing PipelineFinalizerTests cover typed-evidence finalization,
/// stale-generation rejection, and single-task restart before generic
/// recovery. These tests close the remaining gaps:
///   - a crash *after* the report is stored (`.reportStored`) still recovers
///     idempotently without writing a second final report;
///   - recovering one task never releases another task's thread/worktree locks;
///   - several concurrently pending finalizations recover independently.
final class FinalizationRecoveryIsolationTests: XCTestCase {
  func testReportStoredCrashRecoversWithoutDuplicatingReportOrReleasingOtherLocks() async throws {
    let fixture = try await makeFixture(projectCount: 2)
    let first = try await driveVerifying(fixture, index: 0)
    let second = try await driveVerifying(fixture, index: 1)

    let scope = try makeScope(first, projectIndex: 0)
    let document = try makeReport(scope: scope, projectIndex: 0)
    try await storeEvidence(scope: scope, fixture: fixture)

    let supervisorPayload: PipelineSupervisorFinalEvidence? = try await fixture.artifacts
      .trustedPayload(for: scope, kind: .supervisorFinalDecision)
    let supervisor = try XCTUnwrap(supervisorPayload)
    let metadata = try PipelineReportMetadataEvidence(
      scope: scope,
      schemaVersion: document.report.schemaVersion,
      status: document.report.status,
      reportJSON: document.json,
      supervisorDecisionDigest: supervisor.decisionDigest
    )
    _ = try await fixture.artifacts.store(
      scope: scope,
      kind: .reportMetadata,
      payload: metadata
    )
    _ = try await fixture.coordinator.preparePipelineFinalization(
      taskID: scope.taskID,
      expectedBinding: try XCTUnwrap(first.aggregate.binding),
      expectedSequence: scope.eventSequence,
      reportReference: metadata.reportReference,
      reportDigest: metadata.reportDigest,
      supervisorDecisionDigest: metadata.supervisorDecisionDigest
    )
    let storedAt = Date(timeIntervalSince1970: 300)
    _ = try await fixture.reports.storeFinalReport(document, storedAt: storedAt)
    _ = try await fixture.artifacts.advance(scope, to: .reportStored, at: storedAt)

    let firstLocksBefore = try await fixture.eventStore.lockKeysOwned(by: first.aggregate.id)
    let secondLocksBefore = try await fixture.eventStore.lockKeysOwned(by: second.aggregate.id)
    XCTAssertEqual(firstLocksBefore.count, 2)
    XCTAssertEqual(secondLocksBefore.count, 2)

    let restarted = PipelineFinalizer(
      artifacts: fixture.artifacts,
      coordinator: fixture.coordinator,
      reports: fixture.reports
    )
    let recovered = try await restarted.recoverPendingFinalizations()
    XCTAssertEqual(recovered.map(\.aggregate.id), [first.aggregate.id])
    XCTAssertEqual(recovered.map(\.aggregate.phase), [.completed])

    let afterFirst = try await fixture.coordinator.task(first.aggregate.id)
    XCTAssertEqual(afterFirst.aggregate.phase, .completed)
    let firstLocksAfter = try await fixture.eventStore.lockKeysOwned(by: first.aggregate.id)
    XCTAssertTrue(firstLocksAfter.isEmpty)

    // The unrelated verifying task must keep both of its locks.
    let afterSecond = try await fixture.coordinator.task(second.aggregate.id)
    XCTAssertEqual(afterSecond.aggregate.phase, .verifying)
    let secondLocksAfter = try await fixture.eventStore.lockKeysOwned(by: second.aggregate.id)
    XCTAssertEqual(secondLocksAfter.count, 2)

    // Recovery is idempotent and must not write a second final report.
    let replayed = try await restarted.recoverPendingFinalizations()
    XCTAssertTrue(replayed.isEmpty)
    let storedReport = try await fixture.reports.finalReport(for: first.aggregate.id)
    let stored = try XCTUnwrap(storedReport)
    XCTAssertEqual(stored.json, document.json)
    XCTAssertEqual(stored.metadata.storedAt, storedAt)
    XCTAssertEqual(afterFirst.aggregate.reportReference, metadata.reportReference)
  }

  func testRecoveryFinalizesMultiplePendingFinalizationsIndependently() async throws {
    let fixture = try await makeFixture(projectCount: 2)
    let first = try await driveVerifying(fixture, index: 0)
    let second = try await driveVerifying(fixture, index: 1)

    let firstScope = try makeScope(first, projectIndex: 0)
    let secondScope = try makeScope(second, projectIndex: 1)
    let firstDocument = try makeReport(scope: firstScope, projectIndex: 0)
    let secondDocument = try makeReport(scope: secondScope, projectIndex: 1)
    try await storeEvidence(scope: firstScope, fixture: fixture)
    try await storeEvidence(scope: secondScope, fixture: fixture)
    try await storeReportMetadata(scope: firstScope, document: firstDocument, fixture: fixture)
    try await storeReportMetadata(scope: secondScope, document: secondDocument, fixture: fixture)

    let restarted = PipelineFinalizer(
      artifacts: fixture.artifacts,
      coordinator: fixture.coordinator,
      reports: fixture.reports
    )
    let recovered = try await restarted.recoverPendingFinalizations()

    XCTAssertEqual(Set(recovered.map(\.aggregate.id)), [first.aggregate.id, second.aggregate.id])
    XCTAssertEqual(Set(recovered.map(\.aggregate.phase)), [.completed])
    let firstLocksAfter = try await fixture.eventStore.lockKeysOwned(by: first.aggregate.id)
    let secondLocksAfter = try await fixture.eventStore.lockKeysOwned(by: second.aggregate.id)
    XCTAssertTrue(firstLocksAfter.isEmpty)
    XCTAssertTrue(secondLocksAfter.isEmpty)
    let firstReportOptional = try await fixture.reports.finalReport(for: first.aggregate.id)
    let secondReportOptional = try await fixture.reports.finalReport(for: second.aggregate.id)
    let firstReport = try XCTUnwrap(firstReportOptional)
    let secondReport = try XCTUnwrap(secondReportOptional)
    XCTAssertEqual(firstReport.json, firstDocument.json)
    XCTAssertEqual(secondReport.json, secondDocument.json)
    XCTAssertNotEqual(firstReport.metadata.threadID, secondReport.metadata.threadID)
  }

  // MARK: - Fixture

  private struct Fixture {
    let eventStore: EventStore
    let coordinator: TaskCoordinator
    let artifacts: PipelineArtifactStore
    let reports: ApplicationRepository
    let runtime: IsolationRuntime
    let taskIDs: [TaskID]
  }

  private func makeFixture(projectCount: Int) async throws -> Fixture {
    let eventStore = try EventStore.inMemory()
    let runtime = IsolationRuntime()
    let coordinator = TaskCoordinator(
      store: eventStore,
      admission: IsolationAdmission(),
      runtime: runtime
    )
    var taskIDs: [TaskID] = []
    for index in 0..<projectCount {
      let submitted = try await coordinator.submit(
        origin: "test",
        submission: submission(projectIndex: index)
      )
      _ = try await waitForPhase(.running, taskID: submitted.aggregate.id, coordinator: coordinator)
      taskIDs.append(submitted.aggregate.id)
    }
    return Fixture(
      eventStore: eventStore,
      coordinator: coordinator,
      artifacts: try PipelineArtifactStore.inMemory(),
      reports: try ApplicationRepository.inMemory(),
      runtime: runtime,
      taskIDs: taskIDs
    )
  }

  private func driveVerifying(_ fixture: Fixture, index: Int) async throws -> TaskProjection {
    let taskID = fixture.taskIDs[index]
    await fixture.runtime.emit(.turnCompleted, taskID: taskID)
    return try await waitForPhase(.verifying, taskID: taskID, coordinator: fixture.coordinator)
  }

  private func projectID(_ index: Int) -> ProjectID {
    ProjectID(rawValue: "project-isolation-\(index)")
  }

  private func submission(projectIndex: Int) -> TaskSubmission {
    TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "isolation-\(UUID().uuidString)"),
      projectID: projectID(projectIndex),
      thread: .new,
      execution: ExecutionOptions(
        model: "gpt-5",
        effort: "high",
        permissionMode: "read-only",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(enabled: true, model: "luna", effort: "medium"),
      contract: TaskContract(
        goal: "Complete a bounded pipeline task",
        acceptanceCriteria: ["Persist a final report"]
      )
    )
  }

  private func makeScope(
    _ projection: TaskProjection,
    projectIndex: Int
  ) throws -> TaskEvidenceScope {
    let binding = try XCTUnwrap(projection.aggregate.binding)
    let generation = try XCTUnwrap(Int64(exactly: binding.turnGeneration))
    return try TaskEvidenceScope(
      taskID: projection.aggregate.id,
      projectID: projectID(projectIndex),
      threadID: binding.threadID,
      turnID: binding.turnID,
      generation: generation,
      eventSequence: projection.lastSequence
    )
  }

  private func storeEvidence(
    scope: TaskEvidenceScope,
    fixture: Fixture
  ) async throws {
    let artifacts = fixture.artifacts
    _ = try await artifacts.begin(scope)
    _ = try await artifacts.store(scope: scope, kind: .gitBaseline, payload: gitBaseline(scope))
    _ = try await artifacts.advance(scope, to: .baselineCaptured)
    _ = try await artifacts.advance(scope, to: .turnCompleted)
    _ = try await artifacts.store(scope: scope, kind: .gitFinal, payload: gitFinal(scope))
    _ = try await artifacts.advance(scope, to: .gitFinalCaptured)
    let result = verificationResult()
    _ = try await artifacts.store(
      scope: scope,
      kind: .verification(result.commandID.rawValue),
      payload: result
    )
    _ = try await artifacts.advance(scope, to: .verificationCompleted)
    let supervisor = try PipelineSupervisorFinalEvidence(
      scope: scope,
      checkpointStage: .final,
      decision: supervisorDecision()
    )
    _ = try await artifacts.store(scope: scope, kind: .supervisorFinalDecision, payload: supervisor)
    _ = try await artifacts.advance(scope, to: .supervisorReviewed)
  }

  private func storeReportMetadata(
    scope: TaskEvidenceScope,
    document: FinalReportDocument,
    fixture: Fixture
  ) async throws {
    let supervisorPayload: PipelineSupervisorFinalEvidence? = try await fixture.artifacts
      .trustedPayload(for: scope, kind: .supervisorFinalDecision)
    let supervisor = try XCTUnwrap(supervisorPayload)
    let metadata = try PipelineReportMetadataEvidence(
      scope: scope,
      schemaVersion: document.report.schemaVersion,
      status: document.report.status,
      reportJSON: document.json,
      supervisorDecisionDigest: supervisor.decisionDigest
    )
    _ = try await fixture.artifacts.store(scope: scope, kind: .reportMetadata, payload: metadata)
  }

  private func makeReport(
    scope: TaskEvidenceScope,
    projectIndex: Int
  ) throws -> FinalReportDocument {
    let result = verificationResult()
    let verification = VerificationEvidence(
      id: result.commandID.rawValue,
      name: result.executableName,
      required: result.required,
      status: .passed,
      exitCode: result.exitCode
    )
    return try ReportBuilder().build(
      from: FinalReportInput(
        taskID: scope.taskID.rawValue,
        status: .completed,
        project: "Project \(projectIndex)",
        appServer: AppServerEvidence(
          threadID: scope.threadID.rawValue,
          model: "gpt-5",
          effort: "high",
          terminalState: .completed,
          startedAt: Date(timeIntervalSince1970: 1),
          completedAt: Date(timeIntervalSince1970: 30)
        ),
        git: GitEvidence(
          baselineCaptured: true,
          finalStateCaptured: true,
          dirtyAtStart: false,
          changedFiles: [],
          diffStat: "No Git diff available."
        ),
        verification: [verification],
        supervisor: SupervisorEvidence(
          model: "luna",
          effort: "medium",
          checks: 1,
          steers: 0,
          finalDecision: .finalAccept
        ),
        policy: PolicyEvidence(evaluationCompleted: true)
      )
    )
  }

  private func gitBaseline(_ scope: TaskEvidenceScope) -> GitBaselineEvidence {
    GitBaselineEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/private/project-\(scope.projectID.rawValue)",
      rootIdentity: GitRootIdentity(device: 1, inode: 2),
      capturedAt: Date(timeIntervalSince1970: 10),
      status: .notGitRepository,
      changeAttribution: .unavailableForNonGitProject
    )
  }

  private func gitFinal(_ scope: TaskEvidenceScope) -> GitFinalEvidence {
    GitFinalEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/private/project-\(scope.projectID.rawValue)",
      capturedAt: Date(timeIntervalSince1970: 20),
      status: .notGitRepository,
      diffStat: "No Git diff available.",
      changedFiles: [],
      untrackedFiles: [],
      patch: nil,
      changeAttribution: .unavailableForNonGitProject
    )
  }

  private func verificationResult() -> VerificationRunResult {
    VerificationRunResult(
      commandID: VerificationCommandIdentifier(
        rawValue: "vcmd_" + String(repeating: "a", count: 64)
      )!,
      commandIndex: 0,
      executableName: "swift",
      required: true,
      status: .passed,
      exitCode: 0,
      durationMilliseconds: 10,
      standardOutput: VerificationOutputSummary(data: Data(), truncated: false),
      standardError: VerificationOutputSummary(data: Data(), truncated: false)
    )
  }

  private func supervisorDecision() throws -> SupervisorDecision {
    try SupervisorDecision(
      decision: .finalAccept,
      risk: .low,
      summary: "All final evidence is consistent.",
      confidence: 0.99
    )
  }

  private func waitForPhase(
    _ phase: TaskPhase,
    taskID: TaskID,
    coordinator: TaskCoordinator
  ) async throws -> TaskProjection {
    for _ in 0..<200 {
      let current = try await coordinator.task(taskID)
      if current.aggregate.phase == phase { return current }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Task did not reach \(phase)")
    return try await coordinator.task(taskID)
  }
}

private struct IsolationAdmission: TaskAdmissionPolicy {
  func decision(for _: TaskSubmission) -> TaskAdmissionDecision { .start }
}

private actor IsolationRuntime: TaskExecutionRuntime {
  private var continuations: [TaskID: AsyncStream<TaskExecutionObservation>.Continuation] = [:]
  private var counter = 0

  func lockKeys(for submission: TaskSubmission) -> [String] {
    [
      "thread:new:\(submission.idempotencyKey.rawValue)",
      "worktree:\(submission.projectID.rawValue)",
    ]
  }

  func start(taskID: TaskID, submission _: TaskSubmission) -> TaskExecutionSession {
    var continuation: AsyncStream<TaskExecutionObservation>.Continuation!
    let stream = AsyncStream<TaskExecutionObservation> { continuation = $0 }
    continuations[taskID] = continuation
    counter += 1
    return TaskExecutionSession(
      binding: ExecutionBinding(
        threadID: ThreadID(rawValue: "thread-isolation-\(counter)"),
        turnID: TurnID(rawValue: "turn-isolation-\(counter)"),
        turnGeneration: 1
      ),
      observations: stream
    )
  }

  func resolveApproval(taskID _: TaskID, approvalID _: ApprovalID, approved _: Bool) {}
  func interrupt(taskID _: TaskID, binding _: ExecutionBinding) {}

  func emit(_ observation: TaskExecutionObservation, taskID: TaskID) {
    continuations[taskID]?.yield(observation)
  }
}
