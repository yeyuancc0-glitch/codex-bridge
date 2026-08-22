import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgeReporting
import BridgeRepositories
import BridgeSupervisor
import BridgeVerification
import Crypto
import Foundation

public enum PipelineFinalizerError: Error, Equatable, Sendable {
  case scopeMismatch
  case taskStateMismatch(TaskPhase)
  case stageMismatch(PipelineStage)
  case missingEvidence(PipelineArtifactKind)
  case invalidGitEvidence
  case invalidVerificationEvidence(String)
  case invalidSupervisorEvidence
  case invalidReport(String)
  case storedReportMismatch
}

public actor PipelineFinalizer {
  private let artifacts: PipelineArtifactStore
  private let coordinator: TaskCoordinator
  private let reports: any FinalReportStore

  public init(
    artifacts: PipelineArtifactStore,
    coordinator: TaskCoordinator,
    reports: any FinalReportStore
  ) {
    self.artifacts = artifacts
    self.coordinator = coordinator
    self.reports = reports
  }

  public func finalize(
    scope: TaskEvidenceScope,
    report document: FinalReportDocument,
    at date: Date = Date()
  ) async throws -> TaskProjection {
    guard date.timeIntervalSince1970.isFinite else {
      throw PipelineFinalizerError.invalidReport("storedAt")
    }
    let finalization = try await requiredFinalization(scope)
    let current = try await coordinator.task(scope.taskID)
    try validateTask(current, scope: scope)
    guard [.supervisorReviewed, .reportStored, .completed].contains(finalization.stage) else {
      throw PipelineFinalizerError.stageMismatch(finalization.stage)
    }

    let evidence = try await loadEvidence(scope)
    try validateGit(evidence.baseline, final: evidence.final, scope: scope)
    try validateVerification(evidence.verification, report: document.report)
    try validateCompletionReview(evidence, scope: scope)
    try validateReport(
      document,
      task: current,
      scope: scope,
      baseline: evidence.baseline,
      final: evidence.final,
      supervisor: evidence.supervisor,
      deterministicPolicy: evidence.deterministicPolicy
    )

    let reportDigest = Self.digest(document.json)
    let reportEvidence = try PipelineReportMetadataEvidence(
      scope: scope,
      schemaVersion: document.report.schemaVersion,
      status: document.report.status,
      reportJSON: document.json,
      supervisorDecisionDigest: evidence.authorityDigest
    )
    guard reportEvidence.reportDigest == reportDigest else {
      throw PipelineFinalizerError.invalidReport("digest")
    }
    _ = try await artifacts.store(
      scope: scope,
      kind: .reportMetadata,
      payload: reportEvidence,
      at: date
    )
    if current.aggregate.phase == .completed {
      guard current.aggregate.reportReference == reportEvidence.reportReference,
        finalization.stage == .reportStored || finalization.stage == .completed
      else {
        throw PipelineFinalizerError.scopeMismatch
      }
      try await validateStoredReport(document, expected: reportEvidence)
      _ = try await artifacts.advance(scope, to: .completed, at: date)
      return current
    }
    guard current.aggregate.phase == .verifying else {
      throw PipelineFinalizerError.taskStateMismatch(current.aggregate.phase)
    }

    guard let binding = current.aggregate.binding else {
      throw PipelineFinalizerError.scopeMismatch
    }
    let reservation = try await coordinator.preparePipelineFinalization(
      taskID: scope.taskID,
      expectedBinding: binding,
      expectedSequence: scope.eventSequence,
      reportReference: reportEvidence.reportReference,
      reportDigest: reportEvidence.reportDigest,
      supervisorDecisionDigest: reportEvidence.supervisorDecisionDigest
    )
    try await storeAndValidateReport(document, expected: reportEvidence, at: date)
    _ = try await artifacts.advance(scope, to: .reportStored, at: date)
    let completed = try await coordinator.commitPipelineFinalization(reservation)
    _ = try await artifacts.advance(scope, to: .completed, at: date)
    return completed
  }

  public func recoverPendingFinalizations(
    batchSize: Int = 32,
    at date: Date = Date()
  ) async throws -> [TaskProjection] {
    var recovered: [TaskProjection] = []
    while recovered.count < PipelineArtifactStore.maximumActiveScopes {
      let remaining = PipelineArtifactStore.maximumActiveScopes - recovered.count
      let pending = try await artifacts.recoverableFinalizations(
        limit: min(batchSize, remaining)
      )
      guard !pending.isEmpty else { break }
      for record in pending {
        try Task.checkCancellation()
        guard
          let metadata: PipelineReportMetadataEvidence = try await artifacts.trustedPayload(
            for: record.scope,
            kind: .reportMetadata
          )
        else { throw PipelineFinalizerError.missingEvidence(.reportMetadata) }
        let document = try ReportBuilder().restore(canonicalJSON: metadata.reportJSON)
        recovered.append(try await finalize(scope: record.scope, report: document, at: date))
      }
    }
    return recovered
  }

  private struct LoadedEvidence {
    let baseline: GitBaselineEvidence
    let final: GitFinalEvidence
    let verification: [PipelineVerificationEvidence]
    let supervisor: PipelineSupervisorFinalEvidence?
    let deterministicPolicy: PipelineDeterministicPolicyFinalEvidence?

    var authorityDigest: String {
      supervisor?.decisionDigest ?? deterministicPolicy?.decisionDigest ?? ""
    }
  }

  private func requiredFinalization(_ scope: TaskEvidenceScope) async throws
    -> PipelineFinalizationRecord
  {
    guard let record = try await artifacts.finalization(for: scope.taskID), record.scope == scope
    else { throw PipelineFinalizerError.scopeMismatch }
    return record
  }

  private func loadEvidence(_ scope: TaskEvidenceScope) async throws -> LoadedEvidence {
    guard
      let baseline: GitBaselineEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .gitBaseline
      )
    else { throw PipelineFinalizerError.missingEvidence(.gitBaseline) }
    guard
      let final: GitFinalEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .gitFinal
      )
    else { throw PipelineFinalizerError.missingEvidence(.gitFinal) }
    guard let completion = try await artifacts.completionEvidence(for: scope) else {
      throw PipelineFinalizerError.missingEvidence(.supervisorFinalDecision)
    }
    let supervisor = completion.supervisor
    let deterministicPolicy = completion.deterministicPolicy
    let summaries = try await artifacts.artifacts(for: scope)
    var verification: [PipelineVerificationEvidence] = []
    for summary in summaries {
      guard case .verification(let identifier) = summary.kind else { continue }
      guard
        let result: PipelineVerificationEvidence = try await artifacts.trustedPayload(
          for: scope,
          kind: summary.kind
        )
      else { throw PipelineFinalizerError.missingEvidence(summary.kind) }
      guard result.id.rawValue == identifier else {
        throw PipelineFinalizerError.invalidVerificationEvidence(identifier)
      }
      verification.append(result)
    }
    guard !verification.isEmpty else {
      throw PipelineFinalizerError.missingEvidence(.verification("required"))
    }
    verification.sort { $0.id.rawValue < $1.id.rawValue }
    return LoadedEvidence(
      baseline: baseline,
      final: final,
      verification: verification,
      supervisor: supervisor,
      deterministicPolicy: deterministicPolicy
    )
  }

  private func validateTask(_ task: TaskProjection, scope: TaskEvidenceScope) throws {
    let sequenceMatches: Bool
    if task.aggregate.phase == .completed {
      let (minimum, overflow) = scope.eventSequence.addingReportingOverflow(3)
      sequenceMatches = !overflow && task.lastSequence >= minimum
    } else {
      let (reservation, overflow) = scope.eventSequence.addingReportingOverflow(1)
      sequenceMatches =
        task.lastSequence == scope.eventSequence
        || (!overflow && task.lastSequence == reservation)
    }
    guard task.aggregate.id == scope.taskID,
      task.aggregate.submission.projectID == scope.projectID,
      let binding = task.aggregate.binding,
      binding.threadID == scope.threadID,
      binding.turnID == scope.turnID,
      Int64(exactly: binding.turnGeneration) == scope.generation,
      sequenceMatches
    else { throw PipelineFinalizerError.scopeMismatch }
  }

  private func validateGit(
    _ baseline: GitBaselineEvidence,
    final: GitFinalEvidence,
    scope: TaskEvidenceScope
  ) throws {
    guard baseline.projectIdentifier == scope.projectID.rawValue,
      final.projectIdentifier == scope.projectID.rawValue,
      baseline.canonicalRootPath == final.canonicalRootPath,
      baseline.rootIdentity != nil,
      final.patch?.isTruncated != true
    else { throw PipelineFinalizerError.invalidGitEvidence }
  }

  private func validateVerification(
    _ results: [PipelineVerificationEvidence],
    report: FinalReport
  ) throws {
    var reported: [String: VerificationEvidence] = [:]
    for item in report.verification {
      guard reported.updateValue(item, forKey: item.id) == nil else {
        throw PipelineFinalizerError.invalidReport("verification")
      }
    }
    guard reported.count == results.count else {
      throw PipelineFinalizerError.invalidReport("verification")
    }
    for result in results {
      let expected = result.reportingEvidence
      guard let item = reported[result.id.rawValue], item == expected
      else {
        throw PipelineFinalizerError.invalidVerificationEvidence(result.id.rawValue)
      }
    }
  }

  private func validateCompletionReview(
    _ evidence: LoadedEvidence,
    scope: TaskEvidenceScope
  ) throws {
    if let supervisor = evidence.supervisor {
      guard supervisor.scope == scope, supervisor.checkpointStage == .final,
        supervisor.decision.decision == .finalAccept
      else { throw PipelineFinalizerError.invalidSupervisorEvidence }
      return
    }
    guard let deterministicPolicy = evidence.deterministicPolicy,
      deterministicPolicy.scope == scope,
      deterministicPolicy.policy.evaluationCompleted,
      deterministicPolicy.policy.unresolvedBlockers.isEmpty
    else { throw PipelineFinalizerError.invalidSupervisorEvidence }
  }

  private func validateReport(
    _ document: FinalReportDocument,
    task: TaskProjection,
    scope: TaskEvidenceScope,
    baseline: GitBaselineEvidence,
    final: GitFinalEvidence,
    supervisor: PipelineSupervisorFinalEvidence?,
    deterministicPolicy: PipelineDeterministicPolicyFinalEvidence?
  ) throws {
    let report = document.report
    guard report.taskID == scope.taskID.rawValue, report.status == .completed,
      report.threadID == scope.threadID.rawValue,
      report.execution.model == task.aggregate.submission.execution.model,
      report.execution.effort == task.aggregate.submission.execution.effort,
      report.evidence.appServer.threadID == scope.threadID.rawValue,
      report.evidence.appServer.terminalState == .completed,
      report.evidence.completionAuthority
        == (supervisor == nil ? .userOverride : .supervisorFinalAccept),
      report.evidence.git.baselineCaptured,
      report.evidence.git.finalStateCaptured,
      report.evidence.git.dirtyAtStart == baseline.status.isDirty,
      report.evidence.git.diffStat == final.diffStat,
      Set(report.evidence.git.changedFiles.map(\.relativePath))
        == Set(final.changedFiles + final.untrackedFiles),
      report.evidence.policy.evaluationCompleted,
      report.evidence.policy.unresolvedBlockers.isEmpty,
      report.supervisor?.finalDecision == (supervisor == nil ? nil : .finalAccept)
    else { throw PipelineFinalizerError.invalidReport("evidence") }
    if let supervisor {
      guard report.supervisor?.model == task.aggregate.submission.supervisor.model,
        report.supervisor?.effort == task.aggregate.submission.supervisor.effort,
        supervisor.decision.decision == .finalAccept
      else { throw PipelineFinalizerError.invalidReport("supervisor") }
    } else {
      guard let deterministicPolicy,
        report.supervisor == nil,
        report.evidence.userOverride == deterministicPolicy.userOverride,
        report.evidence.policy == deterministicPolicy.policy
      else { throw PipelineFinalizerError.invalidReport("deterministic_policy") }
    }
  }

  private func storeAndValidateReport(
    _ document: FinalReportDocument,
    expected: PipelineReportMetadataEvidence,
    at date: Date
  ) async throws {
    let metadata = try await reports.storeFinalReport(document, storedAt: date)
    guard metadata.taskID == expected.scope.taskID,
      metadata.schemaVersion == expected.schemaVersion,
      metadata.status == expected.status,
      metadata.threadID == expected.scope.threadID.rawValue,
      metadata.byteCount == expected.byteCount
    else { throw PipelineFinalizerError.storedReportMismatch }
    try await validateStoredReport(document, expected: expected)
  }

  private func validateStoredReport(
    _ document: FinalReportDocument,
    expected: PipelineReportMetadataEvidence
  ) async throws {
    guard let stored = try await reports.finalReport(for: expected.scope.taskID),
      stored.json == document.json,
      Self.digest(stored.json) == expected.reportDigest,
      stored.metadata.status == expected.status,
      stored.metadata.threadID == expected.scope.threadID.rawValue,
      stored.metadata.byteCount == expected.byteCount
    else { throw PipelineFinalizerError.storedReportMismatch }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
