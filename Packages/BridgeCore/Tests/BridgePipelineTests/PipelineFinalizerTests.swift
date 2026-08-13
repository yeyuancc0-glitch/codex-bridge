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

final class PipelineFinalizerTests: XCTestCase {
  func testTypedEvidenceFinalizesRealTaskAndIsIdempotent() async throws {
    let fixture = try await makeFixture()
    let document = try makeReport(fixture)

    let first = try await fixture.finalizer.finalize(
      scope: fixture.scope,
      report: document,
      at: Date(timeIntervalSince1970: 200)
    )
    let second = try await fixture.finalizer.finalize(
      scope: fixture.scope,
      report: document,
      at: Date(timeIntervalSince1970: 201)
    )

    XCTAssertEqual(first.aggregate.phase, .completed)
    XCTAssertEqual(second.aggregate.phase, .completed)
    XCTAssertEqual(first.aggregate.reportReference, second.aggregate.reportReference)
    XCTAssertTrue(first.aggregate.reportReference?.hasPrefix("report:sha256:") == true)
    let saga = try await fixture.artifacts.finalization(for: fixture.scope.taskID)
    XCTAssertEqual(saga?.stage, .completed)
    let stored = try await fixture.reports.finalReport(for: fixture.scope.taskID)
    XCTAssertEqual(stored?.json, document.json)
    let locks = try await fixture.eventStore.lockKeysOwned(by: fixture.scope.taskID)
    XCTAssertTrue(locks.isEmpty)
  }

  func testGenericSupervisorPayloadCannotAuthorizeCompletion() async throws {
    let fixture = try await makeFixture(storeTypedSupervisor: false)
    _ = try await fixture.artifacts.store(
      scope: fixture.scope,
      kind: .supervisorFinalDecision,
      payload: ["decision": "final_accept"]
    )
    _ = try await fixture.artifacts.advance(fixture.scope, to: .supervisorReviewed)

    do {
      _ = try await fixture.finalizer.finalize(
        scope: fixture.scope,
        report: makeReport(fixture)
      )
      XCTFail("Expected untyped Supervisor payload rejection")
    } catch {
      XCTAssertEqual(error as? PipelineArtifactStoreError, .corruptRecord)
    }
    let task = try await fixture.coordinator.task(fixture.scope.taskID)
    let stored = try await fixture.reports.finalReport(for: fixture.scope.taskID)
    XCTAssertEqual(task.aggregate.phase, .verifying)
    XCTAssertNil(stored)
  }

  func testWrongThreadAndFailedStatusNeverStoreOrCompleteReport() async throws {
    let fixture = try await makeFixture()
    let wrongThread = try makeReport(fixture, threadID: "thread-other")
    do {
      _ = try await fixture.finalizer.finalize(scope: fixture.scope, report: wrongThread)
      XCTFail("Expected report binding rejection")
    } catch {
      XCTAssertEqual(error as? PipelineFinalizerError, .invalidReport("evidence"))
    }

    let failed = try makeReport(fixture, status: .failed)
    do {
      _ = try await fixture.finalizer.finalize(scope: fixture.scope, report: failed)
      XCTFail("Expected completed-report status rejection")
    } catch {
      XCTAssertEqual(error as? PipelineFinalizerError, .invalidReport("evidence"))
    }
    let task = try await fixture.coordinator.task(fixture.scope.taskID)
    let stored = try await fixture.reports.finalReport(for: fixture.scope.taskID)
    XCTAssertEqual(task.aggregate.phase, .verifying)
    XCTAssertNil(stored)
  }

  func testStaleGenerationScopeCannotCompleteCurrentTask() async throws {
    let fixture = try await makeFixture()
    let stale = try TaskEvidenceScope(
      taskID: fixture.scope.taskID,
      projectID: fixture.scope.projectID,
      threadID: fixture.scope.threadID,
      turnID: TurnID(rawValue: "turn-stale"),
      generation: 2,
      eventSequence: fixture.scope.eventSequence + 1
    )
    _ = try await fixture.artifacts.advance(fixture.scope, to: .superseded)
    _ = try await fixture.artifacts.begin(stale)
    _ = try await fixture.artifacts.store(
      scope: stale,
      kind: .gitBaseline,
      payload: gitBaseline(stale)
    )
    _ = try await fixture.artifacts.advance(stale, to: .baselineCaptured)
    _ = try await fixture.artifacts.advance(stale, to: .turnCompleted)
    _ = try await fixture.artifacts.store(
      scope: stale,
      kind: .gitFinal,
      payload: gitFinal(stale)
    )
    _ = try await fixture.artifacts.advance(stale, to: .gitFinalCaptured)
    _ = try await fixture.artifacts.store(
      scope: stale,
      kind: .verification(fixture.verification.commandID.rawValue),
      payload: fixture.verification
    )
    _ = try await fixture.artifacts.advance(stale, to: .verificationCompleted)
    _ = try await fixture.artifacts.store(
      scope: stale,
      kind: .supervisorFinalDecision,
      payload: try PipelineSupervisorFinalEvidence(
        scope: stale,
        checkpointStage: .final,
        decision: supervisorDecision()
      )
    )
    _ = try await fixture.artifacts.advance(stale, to: .supervisorReviewed)

    do {
      _ = try await fixture.finalizer.finalize(scope: stale, report: makeReport(fixture))
      XCTFail("Expected stale generation rejection")
    } catch {
      XCTAssertEqual(error as? PipelineFinalizerError, .scopeMismatch)
    }
    let task = try await fixture.coordinator.task(fixture.scope.taskID)
    XCTAssertEqual(task.aggregate.phase, .verifying)
  }

  func testPreparedFinalizationSurvivesRestartBeforeGenericRecovery() async throws {
    let fixture = try await makeFixture()
    let document = try makeReport(fixture)
    let storedSupervisor: PipelineSupervisorFinalEvidence? = try await fixture.artifacts
      .trustedPayload(for: fixture.scope, kind: .supervisorFinalDecision)
    let supervisor = try XCTUnwrap(
      storedSupervisor
    )
    let metadata = try PipelineReportMetadataEvidence(
      scope: fixture.scope,
      schemaVersion: document.report.schemaVersion,
      status: document.report.status,
      reportJSON: document.json,
      supervisorDecisionDigest: supervisor.decisionDigest
    )
    _ = try await fixture.artifacts.store(
      scope: fixture.scope,
      kind: .reportMetadata,
      payload: metadata
    )
    let task = try await fixture.coordinator.task(fixture.scope.taskID)
    let binding = try XCTUnwrap(task.aggregate.binding)
    _ = try await fixture.coordinator.preparePipelineFinalization(
      taskID: fixture.scope.taskID,
      expectedBinding: binding,
      expectedSequence: fixture.scope.eventSequence,
      reportReference: metadata.reportReference,
      reportDigest: metadata.reportDigest,
      supervisorDecisionDigest: metadata.supervisorDecisionDigest
    )
    _ = try await fixture.reports.storeFinalReport(document, storedAt: Date())

    let ambiguous = try await fixture.coordinator.recoverIncompleteTasks()
    XCTAssertTrue(ambiguous.isEmpty)
    let beforeRecovery = try await fixture.coordinator.task(fixture.scope.taskID)
    XCTAssertEqual(beforeRecovery.aggregate.phase, .verifying)

    let restarted = PipelineFinalizer(
      artifacts: fixture.artifacts,
      coordinator: fixture.coordinator,
      reports: fixture.reports
    )
    let recovered = try await restarted.recoverPendingFinalizations()
    XCTAssertEqual(recovered.map(\.aggregate.phase), [.completed])
    let locks = try await fixture.eventStore.lockKeysOwned(by: fixture.scope.taskID)
    XCTAssertTrue(locks.isEmpty)
  }

  func testCommitRejectsReservationWithDifferentBinding() async throws {
    let fixture = try await makeFixture()
    let document = try makeReport(fixture)
    let storedSupervisor: PipelineSupervisorFinalEvidence? = try await fixture.artifacts
      .trustedPayload(for: fixture.scope, kind: .supervisorFinalDecision)
    let supervisor = try XCTUnwrap(
      storedSupervisor
    )
    let metadata = try PipelineReportMetadataEvidence(
      scope: fixture.scope,
      schemaVersion: document.report.schemaVersion,
      status: document.report.status,
      reportJSON: document.json,
      supervisorDecisionDigest: supervisor.decisionDigest
    )
    let current = try await fixture.coordinator.task(fixture.scope.taskID)
    let binding = try XCTUnwrap(current.aggregate.binding)
    let reservation = try await fixture.coordinator.preparePipelineFinalization(
      taskID: fixture.scope.taskID,
      expectedBinding: binding,
      expectedSequence: fixture.scope.eventSequence,
      reportReference: metadata.reportReference,
      reportDigest: metadata.reportDigest,
      supervisorDecisionDigest: metadata.supervisorDecisionDigest
    )
    let stale = TaskPipelineFinalizationReservation(
      taskID: reservation.taskID,
      binding: ExecutionBinding(
        threadID: binding.threadID,
        turnID: TurnID(rawValue: "turn-new"),
        turnGeneration: binding.turnGeneration + 1
      ),
      originalSequence: reservation.originalSequence,
      reservationSequence: reservation.reservationSequence,
      reportReference: reservation.reportReference,
      reportDigest: reservation.reportDigest,
      supervisorDecisionDigest: reservation.supervisorDecisionDigest
    )

    do {
      _ = try await fixture.coordinator.commitPipelineFinalization(stale)
      XCTFail("Expected stale reservation rejection")
    } catch {
      XCTAssertEqual(
        error as? TaskCoordinatorError,
        .finalizationReservationMismatch
      )
    }
    let task = try await fixture.coordinator.task(fixture.scope.taskID)
    XCTAssertEqual(task.aggregate.phase, .verifying)
    let locks = try await fixture.eventStore.lockKeysOwned(by: fixture.scope.taskID)
    XCTAssertEqual(locks.count, 2)
  }

  private struct Fixture {
    let eventStore: EventStore
    let runtime: FinalizerRuntime
    let coordinator: TaskCoordinator
    let artifacts: PipelineArtifactStore
    let reports: ApplicationRepository
    let finalizer: PipelineFinalizer
    let scope: TaskEvidenceScope
    let verification: VerificationRunResult
  }

  private func makeFixture(storeTypedSupervisor: Bool = true) async throws -> Fixture {
    let eventStore = try EventStore.inMemory()
    let runtime = FinalizerRuntime()
    let coordinator = TaskCoordinator(
      store: eventStore,
      admission: StartAdmission(),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(
      origin: "test",
      submission: submission()
    )
    _ = try await waitForPhase(
      .running,
      taskID: submitted.aggregate.id,
      coordinator: coordinator
    )
    await runtime.emit(.turnCompleted, taskID: submitted.aggregate.id)
    let verifying = try await waitForPhase(
      .verifying,
      taskID: submitted.aggregate.id,
      coordinator: coordinator
    )
    let binding = try XCTUnwrap(verifying.aggregate.binding)
    let generation = try XCTUnwrap(Int64(exactly: binding.turnGeneration))
    let scope = try TaskEvidenceScope(
      taskID: verifying.aggregate.id,
      projectID: verifying.aggregate.submission.projectID,
      threadID: binding.threadID,
      turnID: binding.turnID,
      generation: generation,
      eventSequence: verifying.lastSequence
    )
    let artifacts = try PipelineArtifactStore.inMemory()
    let reports = try ApplicationRepository.inMemory()
    let finalizer = PipelineFinalizer(
      artifacts: artifacts,
      coordinator: coordinator,
      reports: reports
    )
    let baseline = gitBaseline(scope)
    let final = gitFinal(scope)
    let verification = verificationResult()
    _ = try await artifacts.begin(scope)
    _ = try await artifacts.store(scope: scope, kind: .gitBaseline, payload: baseline)
    _ = try await artifacts.advance(scope, to: .baselineCaptured)
    _ = try await artifacts.advance(scope, to: .turnCompleted)
    _ = try await artifacts.store(scope: scope, kind: .gitFinal, payload: final)
    _ = try await artifacts.advance(scope, to: .gitFinalCaptured)
    _ = try await artifacts.store(
      scope: scope,
      kind: .verification(verification.commandID.rawValue),
      payload: verification
    )
    _ = try await artifacts.advance(scope, to: .verificationCompleted)
    if storeTypedSupervisor {
      let supervisor = try PipelineSupervisorFinalEvidence(
        scope: scope,
        checkpointStage: .final,
        decision: supervisorDecision()
      )
      _ = try await artifacts.store(
        scope: scope,
        kind: .supervisorFinalDecision,
        payload: supervisor
      )
      _ = try await artifacts.advance(scope, to: .supervisorReviewed)
    }
    return Fixture(
      eventStore: eventStore,
      runtime: runtime,
      coordinator: coordinator,
      artifacts: artifacts,
      reports: reports,
      finalizer: finalizer,
      scope: scope,
      verification: verification
    )
  }

  private func submission() -> TaskSubmission {
    TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "pipeline-finalizer"),
      projectID: ProjectID(rawValue: "project-one"),
      thread: .new,
      execution: ExecutionOptions(
        model: "gpt-5",
        effort: "high",
        permissionMode: "read-only",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(enabled: true, model: "luna", effort: "medium"),
      contract: TaskContract(goal: "Finish safely", acceptanceCriteria: ["Tests pass"])
    )
  }

  private func gitBaseline(_ scope: TaskEvidenceScope) -> GitBaselineEvidence {
    GitBaselineEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/private/project",
      rootIdentity: GitRootIdentity(device: 1, inode: 2),
      capturedAt: Date(timeIntervalSince1970: 10),
      status: .notGitRepository,
      changeAttribution: .unavailableForNonGitProject
    )
  }

  private func gitFinal(_ scope: TaskEvidenceScope) -> GitFinalEvidence {
    GitFinalEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/private/project",
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

  private func makeReport(
    _ fixture: Fixture,
    threadID: String? = nil,
    status: FinalReportStatus = .completed
  ) throws -> FinalReportDocument {
    let actualThread = threadID ?? fixture.scope.threadID.rawValue
    let terminal: AppServerTerminalState = status == .completed ? .completed : .failed
    let verification = VerificationEvidence(
      id: fixture.verification.commandID.rawValue,
      name: fixture.verification.executableName,
      required: fixture.verification.required,
      status: .passed,
      exitCode: fixture.verification.exitCode
    )
    return try ReportBuilder().build(
      from: FinalReportInput(
        taskID: fixture.scope.taskID.rawValue,
        status: status,
        project: "Project One",
        appServer: AppServerEvidence(
          threadID: actualThread,
          model: "gpt-5",
          effort: "high",
          terminalState: terminal,
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

private struct StartAdmission: TaskAdmissionPolicy {
  func decision(for _: TaskSubmission) -> TaskAdmissionDecision { .start }
}

private actor FinalizerRuntime: TaskExecutionRuntime {
  private var continuations: [TaskID: AsyncStream<TaskExecutionObservation>.Continuation] = [:]

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
    return TaskExecutionSession(
      binding: ExecutionBinding(
        threadID: ThreadID(rawValue: "thread-one"),
        turnID: TurnID(rawValue: "turn-one"),
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
