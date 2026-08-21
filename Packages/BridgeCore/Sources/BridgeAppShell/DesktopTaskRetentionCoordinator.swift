import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgePersistence
import BridgePipeline
import BridgeRepositories
import BridgeVerification
import CryptoKit
import Foundation

public struct DesktopTaskRetentionRunResult: Equatable, Sendable {
  public let indexedMetadataCount: Int
  public let plannedJobCount: Int
  public let processedJobCount: Int

  public init(indexedMetadataCount: Int, plannedJobCount: Int, processedJobCount: Int) {
    self.indexedMetadataCount = indexedMetadataCount
    self.plannedJobCount = plannedJobCount
    self.processedJobCount = processedJobCount
  }
}

public actor DesktopTaskRetentionCoordinator {
  private static let pageSize = 25
  private static let claimLimit = 5
  private static let leaseDuration: TimeInterval = 300
  private static let retryDelay: TimeInterval = 60

  private let eventStore: EventStore
  private let coordinator: TaskCoordinator
  private let pipelineArtifacts: PipelineArtifactStore
  private let supervision: any DurableSupervisionRetentionStore
  private let patches: GitPatchStore
  private let reports: ApplicationRepository
  private let preflight: any PipelinePreflightRetentionStore
  private let authorizations: any VerificationAuthorizationRetentionStore
  private let ownerInstanceID: String

  public init(
    eventStore: EventStore,
    coordinator: TaskCoordinator,
    pipelineArtifacts: PipelineArtifactStore,
    supervision: any DurableSupervisionRetentionStore,
    patches: GitPatchStore,
    reports: ApplicationRepository,
    preflight: any PipelinePreflightRetentionStore,
    authorizations: any VerificationAuthorizationRetentionStore,
    ownerInstanceID: String = UUID().uuidString.lowercased()
  ) {
    self.eventStore = eventStore
    self.coordinator = coordinator
    self.pipelineArtifacts = pipelineArtifacts
    self.supervision = supervision
    self.patches = patches
    self.reports = reports
    self.preflight = preflight
    self.authorizations = authorizations
    self.ownerInstanceID = ownerInstanceID
  }

  public func run(now: Date = Date()) async throws -> DesktopTaskRetentionRunResult {
    let indexed = try await coordinator.indexMissingTerminalMetadata(limit: Self.pageSize)
    let planned = try await planCandidates(now: now)
    let leaseUntil = now.addingTimeInterval(Self.leaseDuration)
    let jobs = try await eventStore.claimRetentionJobs(
      ownerInstanceID: ownerInstanceID,
      now: now,
      leaseUntil: leaseUntil,
      limit: Self.claimLimit
    )
    var processed = 0
    for job in jobs {
      do {
        try await process(job, now: now)
        processed += 1
      } catch {
        try? await eventStore.releaseRetentionJob(
          taskID: job.taskID,
          ownerInstanceID: ownerInstanceID,
          errorCode: "retention_step_failed",
          retryAt: now.addingTimeInterval(Self.retryDelay),
          at: now
        )
      }
    }
    _ = try await eventStore.pruneCompletedRetentionJobs(limit: Self.pageSize)
    return DesktopTaskRetentionRunResult(
      indexedMetadataCount: indexed,
      plannedJobCount: planned,
      processedJobCount: processed
    )
  }

  private func planCandidates(now: Date) async throws -> Int {
    var cursor: TaskRetentionCandidateCursor?
    var planned = 0
    while planned < Self.pageSize {
      let requestedLimit = min(
        Self.pageSize - planned,
        EventStore.maximumRetentionQueryLimit
      )
      let candidates = try await eventStore.retentionCandidates(
        now: now,
        after: cursor,
        limit: requestedLimit
      )
      guard !candidates.isEmpty else { break }
      for candidate in candidates {
        cursor = try TaskRetentionCandidateCursor(
          completedAt: candidate.metadata.completedAt,
          taskID: candidate.metadata.taskID
        )
        do {
          _ = try await eventStore.planRetentionJob(for: candidate, at: now)
          planned += 1
        } catch EventStoreError.retentionSafetyBlocked {
          continue
        } catch EventStoreError.retainedMetadataConflict {
          continue
        }
        if planned == Self.pageSize { break }
      }
      guard candidates.count == requestedLimit else { break }
    }
    return planned
  }

  private func process(_ initial: TaskRetentionJob, now: Date) async throws {
    var job = initial
    switch job.state {
    case .prepared, .pipelinePruning:
      try await advance(&job, to: .pipelinePruning, at: now)
      try await prunePipeline(taskID: job.taskID, at: now)
      job = try await advance(job, to: .pipelinePruned, at: now)
      fallthrough
    case .pipelinePruned:
      job = try await advance(job, to: .supervisionPruning, at: now)
      fallthrough
    case .supervisionPruning:
      _ = try await supervision.discardForRetention(taskID: job.taskID)
      job = try await advance(job, to: .supervisionPruned, at: now)
      fallthrough
    case .supervisionPruned:
      try await ensureHistoryState(
        taskID: job.taskID, from: .full, to: .archiveAuthoritative, at: now)
      job = try await advance(job, to: .archiveAuthoritative, at: now)
      fallthrough
    case .archiveAuthoritative:
      job = try await advance(
        job, to: job.targetTier == .all ? .eventHistoryPruning : .externalPayloadsPruning, at: now)
      fallthrough
    case .eventHistoryPruning:
      guard job.targetTier == .all else { fallthrough }
      _ = try await eventStore.pruneTaskEventHistory(
        taskID: job.taskID,
        expectedLastEventSequence: job.expectedLastEventSequence,
        expectedProjectionSHA256: job.expectedProjectionSHA256,
        at: now
      )
      job = try await advance(job, to: .eventHistoryPruned, at: now)
      fallthrough
    case .eventHistoryPruned:
      job = try await advance(job, to: .externalPayloadsPruning, at: now)
      fallthrough
    case .externalPayloadsPruning:
      try await pruneExternalPayloads(taskID: job.taskID)
      try await ensureHistoryState(
        taskID: job.taskID,
        from: .archiveAuthoritative,
        to: .payloadsPruned,
        at: now
      )
      job = try await advance(job, to: .payloadsComplete, at: now)
      fallthrough
    case .payloadsComplete:
      guard job.targetTier == .all else {
        _ = try await advance(job, to: .complete, at: now)
        return
      }
      job = try await advance(job, to: .metadataPruning, at: now)
      fallthrough
    case .metadataPruning:
      _ = try await eventStore.purgeTaskMetadata(
        taskID: job.taskID,
        expectedLastEventSequence: job.expectedLastEventSequence,
        expectedProjectionSHA256: job.expectedProjectionSHA256,
        at: now
      )
      job = try await advance(job, to: .metadataPruned, at: now)
      fallthrough
    case .metadataPruned:
      _ = try await advance(job, to: .complete, at: now)
    case .complete:
      return
    }
  }

  private func prunePipeline(taskID: TaskID, at date: Date) async throws {
    guard let manifest = try await pipelineArtifacts.pruneTerminalScopes(for: taskID, at: date)
    else { return }
    for patch in manifest.patches {
      _ = try await patches.remove(patch)
    }
    _ = try await pipelineArtifacts.acknowledgePatchRelease(manifest)
  }

  private func pruneExternalPayloads(taskID: TaskID) async throws {
    if let report = try await reports.finalReport(for: taskID) {
      let digest = SHA256.hash(data: report.json).map { String(format: "%02x", $0) }.joined()
      _ = try await reports.removeFinalReportForRetention(
        taskID: taskID,
        expectedSHA256: digest
      )
    }
    _ = try await preflight.discardForRetention(taskID: taskID)
    switch try await authorizations.removeRecordsForRetention(taskID: taskID.rawValue) {
    case .removed:
      break
    case .blockedByActiveAuthorization:
      throw EventStoreError.retentionSafetyBlocked(taskID)
    }
  }

  private func ensureHistoryState(
    taskID: TaskID,
    from expected: TaskRetentionHistoryState,
    to state: TaskRetentionHistoryState,
    at date: Date
  ) async throws {
    guard let current = try await eventStore.retainedMetadata(for: taskID) else {
      throw EventStoreError.retainedMetadataConflict(taskID)
    }
    guard current.historyState == expected || current.historyState == state else {
      throw EventStoreError.retainedMetadataConflict(taskID)
    }
    guard current.historyState == expected else { return }
    _ = try await eventStore.transitionRetainedMetadataHistory(
      taskID: taskID,
      expectedState: expected,
      to: state,
      at: date
    )
  }

  private func advance(
    _ job: TaskRetentionJob,
    to state: TaskRetentionJobState,
    at date: Date
  ) async throws -> TaskRetentionJob {
    guard job.state != state else { return job }
    return try await eventStore.advanceRetentionJob(
      taskID: job.taskID,
      ownerInstanceID: ownerInstanceID,
      expectedState: job.state,
      to: state,
      at: date
    )
  }

  private func advance(
    _ job: inout TaskRetentionJob,
    to state: TaskRetentionJobState,
    at date: Date
  ) async throws {
    job = try await advance(job, to: state, at: date)
  }
}
