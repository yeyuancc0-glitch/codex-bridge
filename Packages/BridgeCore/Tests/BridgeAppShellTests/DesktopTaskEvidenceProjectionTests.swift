import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgePersistence
import BridgePipeline
import BridgeReporting
import BridgeRepositories
import BridgeSecurity
import BridgeSupervisor
import BridgeVerification
import Foundation
import GRDB
import XCTest

@testable import BridgeAppShell
@testable import BridgeGit

final class DesktopTaskEvidenceProjectionTests: XCTestCase {
  func testPersistentTypedEvidenceProjectsBoundedRedactedNativeValues() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let projection = DesktopTaskEvidenceProjection(
      artifacts: try PipelineArtifactStore(path: fixture.databaseURL.path),
      patches: try GitPatchStore(persistentDirectory: fixture.patchDirectory),
      reports: try ApplicationRepository(path: fixture.databaseURL.path),
      coordinator: fixture.coordinator
    )

    let values = try await projection.project(
      taskID: fixture.scope.taskID,
      deadline: ContinuousClock.now.advanced(by: .seconds(2))
    )

    XCTAssertEqual(values.changedFiles.count, 3)
    XCTAssertTrue(values.changedFiles.contains("Sources/App.swift"))
    XCTAssertEqual(values.changedFiles.filter { $0.hasPrefix("[redacted-") }.count, 2)
    XCTAssertEqual(values.commands.count, 1)
    XCTAssertTrue(values.commands[0].hasPrefix("swift test"))
    XCTAssertFalse(values.commands[0].contains(fixture.privateRoot))
    XCTAssertFalse(values.commands[0].contains("actual-secret-value"))
    XCTAssertTrue(values.diffSummary?.contains("Patch 证据可用") == true)
    XCTAssertFalse(values.diffSummary?.contains("采集时已截断") == true)
    XCTAssertTrue(values.verificationSummary?.contains("passed") == true)
    XCTAssertTrue(values.verificationSummary?.contains("unavailable") == true)
    XCTAssertTrue(values.supervisionSummary?.contains("final_accept") == true)
    XCTAssertTrue(values.supervisionSummary?.contains("置信度 99%") == true)
    assertSafe(values)
  }

  func testMissingScopeProjectsNoInventedEvidence() async throws {
    let fixture = try await Fixture.make(storeEvidence: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let projection = DesktopTaskEvidenceProjection(
      artifacts: try PipelineArtifactStore(path: fixture.databaseURL.path),
      patches: try GitPatchStore(persistentDirectory: fixture.patchDirectory),
      reports: try ApplicationRepository(path: fixture.databaseURL.path),
      coordinator: fixture.coordinator
    )

    let values = try await projection.project(
      taskID: fixture.scope.taskID,
      deadline: ContinuousClock.now.advanced(by: .seconds(2))
    )

    XCTAssertEqual(values, .empty)
  }

  func testScopeForDifferentTurnFailsClosed() async throws {
    let fixture = try await Fixture.make(storeEvidence: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let artifacts = try PipelineArtifactStore(path: fixture.databaseURL.path)
    let wrongScope = try TaskEvidenceScope(
      taskID: fixture.scope.taskID,
      projectID: fixture.scope.projectID,
      threadID: fixture.scope.threadID,
      turnID: TurnID(rawValue: "turn-other"),
      generation: fixture.scope.generation,
      eventSequence: fixture.scope.eventSequence
    )
    _ = try await artifacts.begin(wrongScope)
    let projection = DesktopTaskEvidenceProjection(
      artifacts: artifacts,
      patches: try GitPatchStore(persistentDirectory: fixture.patchDirectory),
      reports: try ApplicationRepository(path: fixture.databaseURL.path),
      coordinator: fixture.coordinator
    )

    do {
      _ = try await projection.project(
        taskID: fixture.scope.taskID,
        deadline: ContinuousClock.now.advanced(by: .seconds(2))
      )
      XCTFail("Expected current task binding mismatch")
    } catch {
      XCTAssertEqual(error as? DesktopTaskEvidenceProjectionError, .scopeMismatch)
    }
  }

  func testCompletedTaskWithoutPipelineEvidenceIsUnavailable() async throws {
    let fixture = try await Fixture.make(storeEvidence: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let current = try await fixture.coordinator.task(fixture.scope.taskID)
    let binding = try XCTUnwrap(current.aggregate.binding)
    let digest = String(repeating: "a", count: 64)
    let reservation = try await fixture.coordinator.preparePipelineFinalization(
      taskID: fixture.scope.taskID,
      expectedBinding: binding,
      expectedSequence: fixture.scope.eventSequence,
      reportReference: "report:sha256:\(digest)",
      reportDigest: digest,
      supervisorDecisionDigest: String(repeating: "b", count: 64)
    )
    _ = try await fixture.coordinator.commitPipelineFinalization(reservation)
    let projection = DesktopTaskEvidenceProjection(
      artifacts: try PipelineArtifactStore(path: fixture.databaseURL.path),
      patches: try GitPatchStore(persistentDirectory: fixture.patchDirectory),
      reports: try ApplicationRepository(path: fixture.databaseURL.path),
      coordinator: fixture.coordinator
    )

    do {
      _ = try await projection.projectBound(
        taskID: fixture.scope.taskID,
        deadline: ContinuousClock.now.advanced(by: .seconds(2))
      )
      XCTFail("Expected missing completed evidence to fail closed")
    } catch {
      XCTAssertEqual(
        error as? DesktopTaskEvidenceProjectionError,
        .evidenceMismatch("scope.missing")
      )
    }
  }

  func testCompletedTaskWithoutStoredReportFailsClosed() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let database = try DatabaseQueue(path: fixture.databaseURL.path)
    try await database.write { db in
      try db.execute(
        sql: "DELETE FROM bridge_repository_final_reports WHERE task_id = ?",
        arguments: [fixture.scope.taskID.rawValue]
      )
    }
    let projection = DesktopTaskEvidenceProjection(
      artifacts: try PipelineArtifactStore(path: fixture.databaseURL.path),
      patches: try GitPatchStore(persistentDirectory: fixture.patchDirectory),
      reports: try ApplicationRepository(path: fixture.databaseURL.path),
      coordinator: fixture.coordinator
    )

    do {
      _ = try await projection.projectBound(
        taskID: fixture.scope.taskID,
        deadline: ContinuousClock.now.advanced(by: .seconds(2))
      )
      XCTFail("Expected a completed task without its stored report to fail closed")
    } catch {
      XCTAssertEqual(error as? DesktopTaskEvidenceProjectionError, .invalidReport)
    }
  }

  func testEvidenceIdentityChangesWithTurnGeneration() async throws {
    let fixture = try await Fixture.make(storeEvidence: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
    let current = try await fixture.coordinator.task(fixture.scope.taskID)
    let preparing = try TaskReducer.reduce(current.aggregate, event: .repairRequested)
    let nextBinding = ExecutionBinding(
      threadID: fixture.scope.threadID,
      turnID: TurnID(rawValue: "turn-next"),
      turnGeneration: UInt64(fixture.scope.generation + 1)
    )
    let next = TaskProjection(
      aggregate: try TaskReducer.reduce(preparing, event: .turnStarted(nextBinding)),
      lastSequence: current.lastSequence + 2
    )

    XCTAssertNotEqual(
      DesktopTaskEvidenceIdentity(current),
      DesktopTaskEvidenceIdentity(next)
    )
  }

  private func assertSafe(_ values: DesktopTaskEvidenceValues) {
    let text =
      values.commands + values.changedFiles
      + [values.diffSummary, values.supervisionSummary, values.verificationSummary].compactMap {
        $0
      }
    XCTAssertTrue(text.allSatisfy(OutboundContentSecurity.isSafe))
    XCTAssertFalse(text.contains { $0.contains("/Users/") || $0.contains("/Volumes/") })
  }
}

private struct Fixture {
  let directory: URL
  let databaseURL: URL
  let patchDirectory: URL
  let privateRoot: String
  let coordinator: TaskCoordinator
  let scope: TaskEvidenceScope

  static func make(storeEvidence shouldStoreEvidence: Bool = true) async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-task-evidence-projection-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let databaseURL = directory.appendingPathComponent("bridge.sqlite")
    let patchDirectory = directory.appendingPathComponent("patches", isDirectory: true)
    let eventStore = try EventStore(path: databaseURL.path)
    let runtime = EvidenceRuntime()
    let coordinator = TaskCoordinator(
      store: eventStore,
      admission: EvidenceAdmission(),
      runtime: runtime
    )
    let submitted = try await coordinator.submit(origin: "test", submission: submission())
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
    let scope = try TaskEvidenceScope(
      taskID: verifying.aggregate.id,
      projectID: verifying.aggregate.submission.projectID,
      threadID: binding.threadID,
      turnID: binding.turnID,
      generation: Int64(binding.turnGeneration),
      eventSequence: verifying.lastSequence
    )
    let privateRoot = "/Volumes/private-user/project"
    if shouldStoreEvidence {
      let metadata = try await storeEvidence(
        databaseURL: databaseURL,
        patchDirectory: patchDirectory,
        privateRoot: privateRoot,
        scope: scope,
        submission: verifying.aggregate.submission
      )
      let reservation = try await coordinator.preparePipelineFinalization(
        taskID: scope.taskID,
        expectedBinding: binding,
        expectedSequence: scope.eventSequence,
        reportReference: metadata.reportReference,
        reportDigest: metadata.reportDigest,
        supervisorDecisionDigest: metadata.supervisorDecisionDigest
      )
      _ = try await coordinator.commitPipelineFinalization(reservation)
      let artifacts = try PipelineArtifactStore(path: databaseURL.path)
      _ = try await artifacts.advance(scope, to: .completed)
    }
    return Fixture(
      directory: directory,
      databaseURL: databaseURL,
      patchDirectory: patchDirectory,
      privateRoot: privateRoot,
      coordinator: coordinator,
      scope: scope
    )
  }

  private static func storeEvidence(
    databaseURL: URL,
    patchDirectory: URL,
    privateRoot: String,
    scope: TaskEvidenceScope,
    submission: TaskSubmission
  ) async throws -> PipelineReportMetadataEvidence {
    let artifacts = try PipelineArtifactStore(path: databaseURL.path)
    let patches = try GitPatchStore(persistentDirectory: patchDirectory)
    let reports = try ApplicationRepository(path: databaseURL.path)
    let patch = try await patches.store(Data("diff --git a/a b/a\n".utf8), isTruncated: false)
    _ = try await artifacts.begin(scope)
    _ = try await artifacts.store(
      scope: scope,
      kind: .gitBaseline,
      payload: gitBaseline(scope: scope, root: privateRoot)
    )
    _ = try await artifacts.advance(scope, to: .baselineCaptured)
    _ = try await artifacts.advance(scope, to: .turnCompleted)
    _ = try await artifacts.store(
      scope: scope,
      kind: .gitFinal,
      payload: gitFinal(scope: scope, root: privateRoot, patch: patch)
    )
    _ = try await artifacts.advance(scope, to: .gitFinalCaptured)
    let passed = verificationResult()
    _ = try await artifacts.store(
      scope: scope,
      kind: .verification(passed.id.rawValue),
      payload: passed
    )
    let unavailable = try PipelineVerificationEvidence.notConfigured()
    _ = try await artifacts.store(
      scope: scope,
      kind: .verification(unavailable.id.rawValue),
      payload: unavailable
    )
    _ = try await artifacts.advance(scope, to: .verificationCompleted)
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
    let report = try finalReport(
      scope: scope,
      submission: submission,
      privateRoot: privateRoot
    )
    _ = try await reports.storeFinalReport(report, storedAt: Date(timeIntervalSince1970: 40))
    let metadata = try PipelineReportMetadataEvidence(
      scope: scope,
      schemaVersion: report.report.schemaVersion,
      status: report.report.status,
      reportJSON: report.json,
      supervisorDecisionDigest: supervisor.decisionDigest
    )
    _ = try await artifacts.store(
      scope: scope,
      kind: .reportMetadata,
      payload: metadata
    )
    _ = try await artifacts.advance(scope, to: .reportStored)
    return metadata
  }

  private static func submission() -> TaskSubmission {
    TaskSubmission(
      idempotencyKey: IdempotencyKey(rawValue: "evidence-projection"),
      projectID: ProjectID(rawValue: "project-evidence"),
      thread: .new,
      execution: ExecutionOptions(
        model: "gpt-test",
        effort: "high",
        permissionMode: "read-only",
        networkAccess: false
      ),
      supervisor: SupervisorOptions(enabled: true, model: "gpt-5.6-luna", effort: "medium"),
      contract: TaskContract(goal: "Project evidence", acceptanceCriteria: ["Evidence is safe"])
    )
  }

  private static func gitFinal(
    scope: TaskEvidenceScope,
    root: String,
    patch: GitPatchHandle
  ) -> GitFinalEvidence {
    GitFinalEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: root,
      capturedAt: Date(timeIntervalSince1970: 20),
      status: .notGitRepository,
      diffStat: "3 files changed at \(root) with api_key=actual-secret-value",
      changedFiles: ["Sources/App.swift", "password=actual-secret-value", root + "/Secret.swift"],
      untrackedFiles: [],
      patch: patch,
      changeAttribution: .attributableFromCleanBaseline
    )
  }

  private static func gitBaseline(
    scope: TaskEvidenceScope,
    root: String
  ) -> GitBaselineEvidence {
    GitBaselineEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: root,
      rootIdentity: GitRootIdentity(device: 1, inode: 2),
      capturedAt: Date(timeIntervalSince1970: 10),
      status: .notGitRepository,
      changeAttribution: .unavailableForNonGitProject
    )
  }

  private static func verificationResult() -> PipelineVerificationEvidence {
    .run(
      VerificationRunResult(
        commandID: VerificationCommandIdentifier(
          rawValue: "vcmd_" + String(repeating: "a", count: 64)
        )!,
        commandIndex: 0,
        executableName: "/usr/bin/swift",
        required: true,
        status: .passed,
        exitCode: 0,
        durationMilliseconds: 10,
        standardOutput: VerificationOutputSummary(data: Data(), truncated: false),
        standardError: VerificationOutputSummary(data: Data(), truncated: false)
      )
    )
  }

  private static func supervisorDecision() throws -> SupervisorDecision {
    try SupervisorDecision(
      decision: .finalAccept,
      risk: .low,
      summary: "Evidence is consistent.",
      confidence: 0.99
    )
  }

  private static func finalReport(
    scope: TaskEvidenceScope,
    submission: TaskSubmission,
    privateRoot: String
  ) throws -> FinalReportDocument {
    try ReportBuilder().build(
      from: FinalReportInput(
        taskID: scope.taskID.rawValue,
        status: .completed,
        project: "Evidence Project",
        appServer: AppServerEvidence(
          threadID: scope.threadID.rawValue,
          model: submission.execution.model,
          effort: submission.execution.effort,
          terminalState: .completed,
          commands: [
            AppServerCommandEvidence(
              sequence: 1,
              executable: "/usr/bin/swift",
              arguments: ["test", privateRoot, "--verbose"],
              exitCode: 0
            )
          ],
          startedAt: Date(timeIntervalSince1970: 10),
          completedAt: Date(timeIntervalSince1970: 30)
        ),
        git: GitEvidence(
          baselineCaptured: true,
          finalStateCaptured: true,
          dirtyAtStart: false,
          changedFiles: [
            GitChangedFileEvidence(relativePath: "Sources/App.swift", change: .modified)
          ],
          diffStat: "1 file changed"
        ),
        verification: [
          VerificationEvidence(
            id: "verification",
            name: "swift test",
            required: true,
            status: .passed,
            exitCode: 0
          )
        ],
        supervisor: SupervisorEvidence(
          model: submission.supervisor.model,
          effort: submission.supervisor.effort,
          checks: 1,
          steers: 0,
          finalDecision: .finalAccept
        ),
        policy: PolicyEvidence(evaluationCompleted: true)
      )
    )
  }

  private static func waitForPhase(
    _ phase: TaskPhase,
    taskID: TaskID,
    coordinator: TaskCoordinator
  ) async throws -> TaskProjection {
    for _ in 0..<200 {
      let task = try await coordinator.task(taskID)
      if task.aggregate.phase == phase { return task }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Task did not reach \(phase)")
    return try await coordinator.task(taskID)
  }
}

private struct EvidenceAdmission: TaskAdmissionPolicy {
  func decision(for _: TaskSubmission) -> TaskAdmissionDecision { .start }
}

private actor EvidenceRuntime: TaskExecutionRuntime {
  private var continuations: [TaskID: AsyncStream<TaskExecutionObservation>.Continuation] = [:]

  func lockKeys(for submission: TaskSubmission) -> [String] {
    ["thread:\(submission.idempotencyKey.rawValue)", "worktree:\(submission.projectID.rawValue)"]
  }

  func start(taskID: TaskID, submission _: TaskSubmission) -> TaskExecutionSession {
    let pair = AsyncStream<TaskExecutionObservation>.makeStream()
    continuations[taskID] = pair.continuation
    return TaskExecutionSession(
      binding: ExecutionBinding(
        threadID: ThreadID(rawValue: "thread-evidence"),
        turnID: TurnID(rawValue: "turn-evidence"),
        turnGeneration: 1
      ),
      observations: pair.stream
    )
  }

  func resolveApproval(taskID _: TaskID, approvalID _: ApprovalID, approved _: Bool) {}
  func interrupt(taskID _: TaskID, binding _: ExecutionBinding) {}

  func emit(_ observation: TaskExecutionObservation, taskID: TaskID) {
    continuations[taskID]?.yield(observation)
  }
}
