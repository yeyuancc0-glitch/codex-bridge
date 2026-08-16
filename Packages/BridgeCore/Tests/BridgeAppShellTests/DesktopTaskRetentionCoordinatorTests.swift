import BridgeAppShell
import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgePersistence
import BridgePipeline
import BridgeRepositories
import BridgeVerification
import Foundation
import XCTest

final class DesktopTaskRetentionCoordinatorTests: XCTestCase {
  func testFailedRetentionRunReleasesLeaseAndRetriesAfterExternalBlock() async throws {
    let now = date(day: 200)
    let fixture = try await makeFixture(taskID: "retention-coordinator-retry", now: now)

    let first = try await fixture.coordinator.run(now: now)
    XCTAssertEqual(first.plannedJobCount, 1)
    XCTAssertEqual(first.processedJobCount, 0)
    let failedJob = try await fixture.eventStore.retentionJob(for: fixture.taskID)
    XCTAssertEqual(failedJob?.state, .externalPayloadsPruning)
    XCTAssertNil(failedJob?.leaseOwner)
    XCTAssertEqual(failedJob?.attemptCount, 1)
    XCTAssertEqual(failedJob?.lastErrorCode, "retention_step_failed")

    let second = try await fixture.coordinator.run(now: now.addingTimeInterval(61))
    XCTAssertEqual(second.processedJobCount, 1)
    let retainedAfterRetry = try await fixture.eventStore.retainedMetadata(for: fixture.taskID)
    let lastSequenceAfterRetry = try await fixture.eventStore.lastEventSequence(for: fixture.taskID)
    XCTAssertNil(retainedAfterRetry)
    XCTAssertNil(lastSequenceAfterRetry)
    let status = try await fixture.eventStore.taskRetentionStatus(now: now.addingTimeInterval(62))
    XCTAssertEqual(status.pendingJobCount, 0)
  }

  func testCoordinatorContinuesFromPersistedPipelineReleaseManifest() async throws {
    let now = date(day: 200)
    let fixture = try await makeFixture(
      taskID: "retention-coordinator-manifest",
      now: now,
      blocksAuthorization: false
    )
    let scope = try TaskEvidenceScope(
      taskID: fixture.taskID,
      projectID: ProjectID(rawValue: "retention-project"),
      threadID: ThreadID(rawValue: "retention-thread"),
      turnID: TurnID(rawValue: "retention-turn"),
      generation: 1,
      eventSequence: 3
    )
    _ = try await fixture.pipeline.begin(scope, at: now)
    _ = try await fixture.pipeline.advance(scope, to: .failed, at: now)
    let manifest = try await fixture.pipeline.pruneTerminalScopes(for: fixture.taskID, at: now)
    XCTAssertNotNil(manifest)
    let persistedManifest = try await fixture.pipeline.patchReleaseManifest(for: fixture.taskID)
    XCTAssertNotNil(persistedManifest)

    _ = try await fixture.coordinator.run(now: now)

    let releasedManifest = try await fixture.pipeline.patchReleaseManifest(for: fixture.taskID)
    let currentScope = try await fixture.pipeline.currentScope(for: fixture.taskID)
    let retainedMetadata = try await fixture.eventStore.retainedMetadata(for: fixture.taskID)
    XCTAssertNil(releasedManifest)
    XCTAssertNil(currentScope)
    XCTAssertNil(retainedMetadata)
  }

  func testReservedNotificationLeaseBlocksEventHistoryRetention() async throws {
    let now = date(day: 200)
    let fixture = try await makeFixture(taskID: "retention-coordinator-notification", now: now)
    let candidates = try await fixture.eventStore.retentionCandidates(now: now, limit: 1)
    let candidate = try XCTUnwrap(candidates.first)
    _ = try await fixture.eventStore.planRetentionJob(for: candidate, at: now)
    let changes = try await fixture.eventStore.changes(after: 0, limit: 10)
    let change = try XCTUnwrap(changes.first)
    _ = try await fixture.eventStore.reserveNotifications(
      consumerID: "retention-test-consumer",
      ownerInstanceID: "retention-test-owner",
      expectedCursor: 0,
      throughChangeID: try await fixture.eventStore.taskChangeHead(),
      candidates: [
        TaskNotificationCandidate(
          stableKey: "retention-test-notification",
          change: change
        )
      ],
      reservedAt: now,
      leaseUntil: now.addingTimeInterval(1_000)
    )

    let result = try await fixture.coordinator.run(now: now)
    XCTAssertEqual(result.processedJobCount, 0)
    let job = try await fixture.eventStore.retentionJob(for: fixture.taskID)
    XCTAssertEqual(job?.state, .eventHistoryPruning)
    XCTAssertNil(job?.leaseOwner)
    let storedMetadata = try await fixture.eventStore.retainedMetadata(for: fixture.taskID)
    let metadata = try XCTUnwrap(storedMetadata)
    XCTAssertEqual(metadata.historyState, .archiveAuthoritative)
    let remainingEvents = try await fixture.eventStore.events(for: fixture.taskID)
    XCTAssertEqual(remainingEvents.count, 3)
  }

  private struct Fixture {
    let eventStore: EventStore
    let pipeline: PipelineArtifactStore
    let coordinator: DesktopTaskRetentionCoordinator
    let taskID: TaskID
  }

  private func makeFixture(
    taskID rawTaskID: String,
    now: Date,
    blocksAuthorization: Bool = true
  ) async throws -> Fixture {
    let taskID = TaskID(rawValue: rawTaskID)
    let eventStore = try EventStore.inMemory()
    let completedAt = date(day: 100)
    var events: [TaskEventEnvelope] = []
    for sequence in 1...3 {
      events.append(
        TaskEventEnvelope(
          taskID: taskID,
          sequence: Int64(sequence),
          schemaVersion: 1,
          source: "retention-test",
          kind: sequence == 3 ? "task.completionRecorded" : "task.progress",
          severity: "info",
          payload: Data("{\"sequence\":\(sequence)}".utf8),
          createdAt: sequence == 3
            ? completedAt : completedAt.addingTimeInterval(-Double(3 - sequence))
        ))
    }
    _ = try await eventStore.claimSubmission(
      origin: "retention-test",
      key: IdempotencyKey(rawValue: "key-(rawTaskID)"),
      requestFingerprint: "fingerprint-(rawTaskID)",
      taskID: taskID,
      initialEvents: events,
      initialSnapshot: TaskStateSnapshot(
        taskID: taskID,
        lastEventSequence: 3,
        schemaVersion: 1,
        payload: Data("snapshot".utf8),
        recoveryRequired: false
      ),
      createdAt: completedAt.addingTimeInterval(-3)
    )
    _ = try await eventStore.indexTerminalRetainedMetadata(
      try TaskRetainedMetadata(
        taskID: taskID,
        terminalPhase: .completed,
        createdAt: completedAt.addingTimeInterval(-3),
        startedAt: completedAt.addingTimeInterval(-2),
        completedAt: completedAt,
        lastEventSequence: 3,
        projectionSchemaVersion: 1,
        projectionPayload: Data("projection".utf8),
        indexedAt: completedAt
      )
    )

    let pipeline = try PipelineArtifactStore.inMemory()
    let supervision = try DurableSupervisionLedger.inMemory()
    let reports = try ApplicationRepository.inMemory()
    let preflight = PipelinePreflightStore.inMemory()
    let authorizations = RetentionAuthorizationStore(shouldBlock: blocksAuthorization)
    let taskCoordinator = TaskCoordinator(
      store: eventStore,
      admission: RetentionAdmission(),
      runtime: RetentionRuntime()
    )
    let retention = DesktopTaskRetentionCoordinator(
      eventStore: eventStore,
      coordinator: taskCoordinator,
      pipelineArtifacts: pipeline,
      supervision: supervision,
      patches: GitPatchStore(),
      reports: reports,
      preflight: preflight,
      authorizations: authorizations,
      ownerInstanceID: "retention-coordinator-test"
    )
    _ = now
    return Fixture(
      eventStore: eventStore, pipeline: pipeline, coordinator: retention, taskID: taskID)
  }

  private func date(day: Int) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400)
  }
}

private struct RetentionAdmission: TaskAdmissionPolicy {
  func decision(for _: TaskSubmission) async throws -> TaskAdmissionDecision { .start }
}

private struct RetentionRuntime: TaskExecutionRuntime {
  enum Error: Swift.Error {
    case unused
  }

  func lockKeys(for _: TaskSubmission) async throws -> [String] { [] }

  func start(taskID _: TaskID, submission _: TaskSubmission) async throws -> TaskExecutionSession {
    throw Error.unused
  }

  func resolveApproval(taskID _: TaskID, approvalID _: ApprovalID, approved _: Bool) async throws {
    throw Error.unused
  }

  func interrupt(taskID _: TaskID, binding _: ExecutionBinding) async throws {
    throw Error.unused
  }
}

private actor RetentionAuthorizationStore: VerificationAuthorizationRetentionStore {
  private var shouldBlock: Bool

  init(shouldBlock: Bool) {
    self.shouldBlock = shouldBlock
  }

  func removeRecordsForRetention(taskID _: String) async throws
    -> VerificationAuthorizationRetentionRemoval
  {
    if shouldBlock {
      shouldBlock = false
      return .blockedByActiveAuthorization
    }
    return .removed(0)
  }
}
