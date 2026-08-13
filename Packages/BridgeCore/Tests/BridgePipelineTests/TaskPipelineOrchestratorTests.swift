import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgePersistence
import BridgeProjects
import BridgeReporting
import BridgeRepositories
import BridgeSecurity
import BridgeSupervisor
import BridgeVerification
import Foundation
import GRDB
import XCTest

@testable import BridgePipeline

final class TaskPipelineOrchestratorTests: XCTestCase {
  func testNoVerificationCommandsProduceUnavailableEvidenceAndComplete() async throws {
    let fixture = try await makeFixture(decision: finalAcceptDecision())

    await fixture.runtime.emit(.turnCompleted, taskID: fixture.taskID)
    let completed = try await waitForPhase(
      .completed,
      taskID: fixture.taskID,
      coordinator: fixture.coordinator
    )

    XCTAssertNotNil(completed.aggregate.reportReference)
    let stored = try await fixture.reports.finalReport(for: fixture.taskID)
    let document = try ReportBuilder().restore(canonicalJSON: XCTUnwrap(stored?.json))
    XCTAssertEqual(document.report.status, .completed)
    XCTAssertEqual(document.report.verification.count, 1)
    XCTAssertEqual(document.report.verification.first?.status, .unavailable)
    XCTAssertEqual(
      document.report.verification.first?.unavailableReason,
      "No verification commands are registered for this project."
    )
    XCTAssertEqual(document.report.supervisor?.finalDecision, .finalAccept)
    let saga = try await fixture.artifacts.finalization(for: fixture.taskID)
    XCTAssertEqual(saga?.stage, .completed)
    let locks = try await fixture.store.lockKeysOwned(by: fixture.taskID)
    XCTAssertTrue(locks.isEmpty)
  }

  func testSupervisorFinalRejectNeverStoresReportOrCompletesTask() async throws {
    let decision = try SupervisorDecision(
      decision: .finalReject,
      risk: .high,
      summary: "Final evidence does not satisfy the task contract.",
      evidence: ["Acceptance evidence is incomplete."],
      confidence: 0.98,
      issueID: "final-review-rejected"
    )
    let fixture = try await makeFixture(decision: decision)

    await fixture.runtime.emit(.turnCompleted, taskID: fixture.taskID)
    let failed = try await waitForPhase(
      .failed,
      taskID: fixture.taskID,
      coordinator: fixture.coordinator
    )

    XCTAssertNil(failed.aggregate.reportReference)
    let stored = try await fixture.reports.finalReport(for: fixture.taskID)
    XCTAssertNil(stored)
    let saga = try await fixture.artifacts.finalization(for: fixture.taskID)
    XCTAssertEqual(saga?.stage, .failed)
    let locks = try await fixture.store.lockKeysOwned(by: fixture.taskID)
    XCTAssertTrue(locks.isEmpty)
    let binding = try XCTUnwrap(failed.aggregate.binding)
    do {
      _ = try await fixture.preflight.startedRecord(taskID: fixture.taskID, binding: binding)
      XCTFail("Expected rejected generation preflight cleanup")
    } catch {
      XCTAssertEqual(error as? PipelinePreflightStoreError, .missing(fixture.taskID))
    }
  }

  func testFailedSagaCleanupRetainsDurablePreflightUntilRecoveryCanFinish() async throws {
    let decision = try SupervisorDecision(
      decision: .finalReject,
      risk: .high,
      summary: "Final evidence does not satisfy the task contract.",
      evidence: ["Acceptance evidence is incomplete."],
      confidence: 0.98,
      issueID: "durable-cleanup-rejected"
    )
    let fixture = try await makeFixture(decision: decision, persistentStores: true)
    let artifactURL = try XCTUnwrap(fixture.artifactStoreURL)
    let injector = try DatabaseQueue(path: artifactURL.path)
    try await injector.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER reject_failed_saga_transition
          BEFORE UPDATE OF stage ON bridge_pipeline_scopes
          WHEN NEW.stage = 'failed'
          BEGIN
            SELECT RAISE(ABORT, 'injected cleanup failure');
          END
          """
      )
    }

    await fixture.runtime.emit(.turnCompleted, taskID: fixture.taskID)
    let failed = try await waitForPhase(
      .failed,
      taskID: fixture.taskID,
      coordinator: fixture.coordinator
    )

    let active = try await fixture.artifacts.finalization(for: fixture.taskID)
    XCTAssertEqual(active?.stage, .verificationCompleted)
    let binding = try XCTUnwrap(failed.aggregate.binding)
    _ = try await fixture.preflight.startedRecord(taskID: fixture.taskID, binding: binding)
    let restartedPreflight = try PipelinePreflightStore(
      path: try XCTUnwrap(fixture.preflightStoreURL).path
    )
    _ = try await restartedPreflight.startedRecord(taskID: fixture.taskID, binding: binding)
    let restartedArtifacts = try PipelineArtifactStore(path: artifactURL.path)
    let restartedActive = try await restartedArtifacts.finalization(for: fixture.taskID)
    XCTAssertEqual(restartedActive?.stage, .verificationCompleted)

    try await injector.write { database in
      try database.execute(sql: "DROP TRIGGER reject_failed_saga_transition")
    }
    _ = try await fixture.orchestrator.recoverPendingPreflights()

    let terminal = try await fixture.artifacts.finalization(for: fixture.taskID)
    XCTAssertEqual(terminal?.stage, .failed)
    do {
      _ = try await fixture.preflight.startedRecord(taskID: fixture.taskID, binding: binding)
      XCTFail("Expected preflight removal after durable saga cleanup")
    } catch {
      XCTAssertEqual(error as? PipelinePreflightStoreError, .missing(fixture.taskID))
    }
  }

  func testSuspendedTurnDiscardsPreflightBeforeNextGenerationStarts() async throws {
    let fixture = try await makeFixture(decision: finalAcceptDecision())
    let first = try await fixture.coordinator.task(fixture.taskID)
    let firstBinding = try XCTUnwrap(first.aggregate.binding)

    _ = try await fixture.coordinator.suspend(taskID: fixture.taskID)
    await fixture.runtime.emit(.turnStopped, taskID: fixture.taskID)
    _ = try await waitForPhase(
      .suspended,
      taskID: fixture.taskID,
      coordinator: fixture.coordinator
    )
    _ = try await fixture.coordinator.resume(taskID: fixture.taskID)
    let resumed = try await waitForPhase(
      .running,
      taskID: fixture.taskID,
      coordinator: fixture.coordinator
    )

    XCTAssertEqual(resumed.aggregate.binding?.turnGeneration, 2)
    XCTAssertEqual(resumed.aggregate.binding?.threadID, firstBinding.threadID)
    XCTAssertNotEqual(resumed.aggregate.binding?.turnID, firstBinding.turnID)
  }

  func testRestartRecoveryContinuesVerifyingPreflightBeforeGenericRecovery() async throws {
    let fixture = try await makeFixture(
      decision: finalAcceptDecision(),
      installLifecycle: false
    )
    await fixture.runtime.emit(.turnCompleted, taskID: fixture.taskID)
    _ = try await waitForPhase(
      .verifying,
      taskID: fixture.taskID,
      coordinator: fixture.coordinator
    )

    let recovered = try await fixture.orchestrator.recoverPendingPreflights()

    XCTAssertEqual(recovered.map(\.aggregate.phase), [.completed])
    let current = try await fixture.coordinator.task(fixture.taskID)
    XCTAssertEqual(current.aggregate.phase, .completed)
    let stored = try await fixture.reports.finalReport(for: fixture.taskID)
    XCTAssertNotNil(stored)
  }

  func testRestartRecoveryClearsSuspendedGenerationBeforeResume() async throws {
    let fixture = try await makeFixture(
      decision: finalAcceptDecision(),
      installLifecycle: false
    )
    _ = try await fixture.coordinator.suspend(taskID: fixture.taskID)
    await fixture.runtime.emit(.turnStopped, taskID: fixture.taskID)
    let suspended = try await waitForPhase(
      .suspended,
      taskID: fixture.taskID,
      coordinator: fixture.coordinator
    )
    let binding = try XCTUnwrap(suspended.aggregate.binding)

    _ = try await fixture.orchestrator.recoverPendingPreflights()

    do {
      _ = try await fixture.preflight.startedRecord(taskID: fixture.taskID, binding: binding)
      XCTFail("Expected stale preflight cleanup")
    } catch {
      XCTAssertEqual(error as? PipelinePreflightStoreError, .missing(fixture.taskID))
    }
    _ = try await fixture.coordinator.resume(taskID: fixture.taskID)
    let resumed = try await waitForPhase(
      .running,
      taskID: fixture.taskID,
      coordinator: fixture.coordinator
    )
    XCTAssertEqual(resumed.aggregate.binding?.turnGeneration, 2)
  }

  private struct Fixture {
    let store: EventStore
    let runtime: OrchestratorRuntime
    let coordinator: TaskCoordinator
    let preflight: PipelinePreflightStore
    let artifacts: PipelineArtifactStore
    let reports: ApplicationRepository
    let orchestrator: TaskPipelineOrchestrator
    let taskID: TaskID
    let directory: URL
    let artifactStoreURL: URL?
    let preflightStoreURL: URL?
  }

  private func makeFixture(
    decision: SupervisorDecision,
    installLifecycle: Bool = true,
    persistentStores: Bool = false
  ) async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-pipeline-orchestrator-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let root = try RegisteredRoot(capturing: directory)
    let projectID = ProjectID(rawValue: "project-orchestrator")
    let project = RegisteredProject(
      id: projectID,
      name: "Pipeline Project",
      primaryRoot: root,
      repositoryRoot: root,
      accessPolicy: ProjectAccessPolicy(),
      verificationCommands: [],
      forbiddenPatterns: [],
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let store = try EventStore.inMemory()
    let runtime = OrchestratorRuntime()
    let relay = DeferredTaskPipelineLifecycle()
    let lifecycle: (any TaskPipelineLifecycle)? = installLifecycle ? relay : nil
    let coordinator = TaskCoordinator(
      store: store,
      admission: OrchestratorAdmission(),
      runtime: runtime,
      pipeline: lifecycle
    )
    let artifactStoreURL =
      persistentStores
      ? directory.appendingPathComponent("pipeline.sqlite") : nil
    let preflightStoreURL =
      persistentStores
      ? directory.appendingPathComponent("preflight.json") : nil
    let artifacts =
      try artifactStoreURL.map { try PipelineArtifactStore(path: $0.path) }
      ?? PipelineArtifactStore.inMemory()
    let reports = try ApplicationRepository.inMemory()
    let preflight =
      try preflightStoreURL.map { try PipelinePreflightStore(path: $0.path) }
      ?? PipelinePreflightStore.inMemory()
    let finalizer = PipelineFinalizer(
      artifacts: artifacts,
      coordinator: coordinator,
      reports: reports
    )
    let baseline = GitBaselineEvidence(
      projectIdentifier: projectID.rawValue,
      canonicalRootPath: root.canonicalPath,
      rootIdentity: GitRootIdentity(device: root.identity.device, inode: root.identity.inode),
      capturedAt: Date(timeIntervalSince1970: 10),
      status: .notGitRepository,
      changeAttribution: .unavailableForNonGitProject
    )
    let final = GitFinalEvidence(
      projectIdentifier: projectID.rawValue,
      canonicalRootPath: root.canonicalPath,
      capturedAt: Date(timeIntervalSince1970: 20),
      status: .notGitRepository,
      diffStat: "No Git diff available.",
      changedFiles: [],
      untrackedFiles: [],
      patch: nil,
      changeAttribution: .unavailableForNonGitProject
    )
    let orchestrator = TaskPipelineOrchestrator(
      preflight: preflight,
      artifacts: artifacts,
      finalizer: finalizer,
      coordinator: coordinator,
      projects: ClosureTaskPipelineProjectProvider { id in id == projectID ? project : nil },
      git: FixedGitEvidence(baseline: baseline, final: final),
      verification: ClosureTaskPipelineVerificationRunner { _, _, _ in [] },
      supervisor: FixedSupervisorReviewer(decision: decision),
      policy: ClosureTaskPipelinePolicyEvaluator { _ in
        PolicyEvidence(evaluationCompleted: true)
      }
    )
    if installLifecycle { try await relay.install(orchestrator) }
    let submitted = try await coordinator.submit(
      origin: "test",
      submission: submission(projectID: projectID)
    )
    let running = try await waitForPhase(
      .running,
      taskID: submitted.aggregate.id,
      coordinator: coordinator
    )
    if !installLifecycle {
      let binding = try XCTUnwrap(running.aggregate.binding)
      let preparation = PreparedTaskExecution(
        threadID: binding.threadID,
        turnGeneration: binding.turnGeneration,
        lockKeys: try await runtime.lockKeys(
          for: running.aggregate.submission,
          previousBinding: nil
        )
      )
      let preStart = TaskPipelinePreStartContext(
        taskID: submitted.aggregate.id,
        submission: running.aggregate.submission,
        preparation: preparation,
        startIntentSequence: max(1, running.lastSequence - 1)
      )
      try await preflight.storeBaseline(context: preStart, baseline: baseline)
      try await preflight.recordStartedTurn(
        TaskPipelineStartedContext(preStart: preStart, binding: binding)
      )
    }
    return Fixture(
      store: store,
      runtime: runtime,
      coordinator: coordinator,
      preflight: preflight,
      artifacts: artifacts,
      reports: reports,
      orchestrator: orchestrator,
      taskID: submitted.aggregate.id,
      directory: directory,
      artifactStoreURL: artifactStoreURL,
      preflightStoreURL: preflightStoreURL
    )
  }

  private func submission(projectID: ProjectID) -> TaskSubmission {
    TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "orchestrator-\(UUID().uuidString)"),
      projectID: projectID,
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

  private func finalAcceptDecision() throws -> SupervisorDecision {
    try SupervisorDecision(
      decision: .finalAccept,
      risk: .low,
      summary: "The final evidence satisfies the task contract.",
      evidence: ["The turn completed and deterministic checks finished."],
      confidence: 0.99
    )
  }

  private func waitForPhase(
    _ phase: TaskPhase,
    taskID: TaskID,
    coordinator: TaskCoordinator
  ) async throws -> TaskProjection {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      let current = try await coordinator.task(taskID)
      if current.aggregate.phase == phase { return current }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Task did not reach \(phase)")
    return try await coordinator.task(taskID)
  }
}

private struct OrchestratorAdmission: TaskAdmissionPolicy {
  func decision(for _: TaskSubmission) -> TaskAdmissionDecision { .start }
}

private struct FixedGitEvidence: TaskPipelineGitEvidenceCollecting {
  let baseline: GitBaselineEvidence
  let final: GitFinalEvidence

  func captureBaseline(projectIdentifier: String) throws -> GitBaselineEvidence {
    guard projectIdentifier == baseline.projectIdentifier else {
      throw TaskPipelineOrchestratorError.scopeMismatch
    }
    return baseline
  }

  func captureFinal(
    projectIdentifier: String,
    baseline: GitBaselineEvidence
  ) throws -> GitFinalEvidence {
    guard projectIdentifier == final.projectIdentifier,
      baseline.projectIdentifier == projectIdentifier
    else { throw TaskPipelineOrchestratorError.scopeMismatch }
    return final
  }
}

private struct FixedSupervisorReviewer: TaskPipelineSupervisorReviewing {
  let decision: SupervisorDecision

  func review(
    _: SupervisorCheckpoint,
    root _: RegisteredRoot,
    model _: String,
    effort _: String
  ) -> SupervisorDecision {
    decision
  }
}

private actor OrchestratorRuntime: DurableTaskExecutionRuntime {
  private var continuations: [TaskID: AsyncStream<TaskExecutionObservation>.Continuation] = [:]
  private var bindings: [TaskID: ExecutionBinding] = [:]

  func lockKeys(
    for submission: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) -> [String] {
    let thread = previousBinding?.threadID.rawValue ?? "new:\(submission.idempotencyKey.rawValue)"
    return ["thread:\(thread)", "worktree:\(submission.projectID.rawValue)"]
  }

  func lockKeys(for submission: TaskSubmission) -> [String] {
    lockKeys(for: submission, previousBinding: nil)
  }

  func prepare(
    taskID _: TaskID,
    submission: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) -> PreparedTaskExecution {
    let generation = (previousBinding?.turnGeneration ?? 0) + 1
    let thread = previousBinding?.threadID ?? ThreadID(rawValue: "thread-orchestrator")
    return PreparedTaskExecution(
      threadID: thread,
      turnGeneration: generation,
      lockKeys: ["thread:\(thread.rawValue)", "worktree:\(submission.projectID.rawValue)"]
    )
  }

  func startPrepared(
    taskID: TaskID,
    submission _: TaskSubmission,
    preparation: PreparedTaskExecution
  ) -> TaskExecutionSession {
    var continuation: AsyncStream<TaskExecutionObservation>.Continuation!
    let observations = AsyncStream<TaskExecutionObservation> { continuation = $0 }
    continuations[taskID] = continuation
    let binding = ExecutionBinding(
      threadID: preparation.threadID,
      turnID: TurnID(rawValue: "turn-orchestrator-\(preparation.turnGeneration)"),
      turnGeneration: preparation.turnGeneration
    )
    bindings[taskID] = binding
    return TaskExecutionSession(binding: binding, observations: observations)
  }

  func cancelPreparation(taskID _: TaskID) {}

  func start(taskID: TaskID, submission: TaskSubmission) async throws -> TaskExecutionSession {
    try await start(taskID: taskID, submission: submission, previousBinding: nil)
  }

  func start(
    taskID: TaskID,
    submission: TaskSubmission,
    previousBinding: ExecutionBinding?
  ) async throws -> TaskExecutionSession {
    let preparation = prepare(
      taskID: taskID,
      submission: submission,
      previousBinding: previousBinding
    )
    return startPrepared(taskID: taskID, submission: submission, preparation: preparation)
  }

  func resolveApproval(taskID _: TaskID, approvalID _: ApprovalID, approved _: Bool) {}
  func interrupt(taskID _: TaskID, binding _: ExecutionBinding) {}

  func abortSession(taskID: TaskID, binding: ExecutionBinding) throws {
    guard bindings[taskID] == binding else {
      throw OrchestratorRuntimeError.bindingMismatch
    }
    bindings[taskID] = nil
    continuations.removeValue(forKey: taskID)?.finish()
  }

  func emit(_ observation: TaskExecutionObservation, taskID: TaskID) {
    continuations[taskID]?.yield(observation)
  }
}

private enum OrchestratorRuntimeError: Error {
  case bindingMismatch
}
