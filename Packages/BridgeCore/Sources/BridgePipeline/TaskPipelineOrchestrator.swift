import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgeProjects
import BridgeReporting
import BridgeSecurity
import BridgeSupervisor
import BridgeVerification
import Foundation

public protocol TaskPipelineProjectProviding: Sendable {
  func project(for id: ProjectID) async throws -> RegisteredProject?
}

public struct ClosureTaskPipelineProjectProvider: TaskPipelineProjectProviding {
  private let body: @Sendable (ProjectID) async throws -> RegisteredProject?

  public init(_ body: @escaping @Sendable (ProjectID) async throws -> RegisteredProject?) {
    self.body = body
  }

  public func project(for id: ProjectID) async throws -> RegisteredProject? {
    try await body(id)
  }
}

public protocol TaskPipelineGitEvidenceCollecting: Sendable {
  func captureBaseline(projectIdentifier: String) async throws -> GitBaselineEvidence
  func captureFinal(
    projectIdentifier: String,
    baseline: GitBaselineEvidence
  ) async throws -> GitFinalEvidence
}

extension GitEvidenceCollector: TaskPipelineGitEvidenceCollecting {}

public protocol TaskPipelineVerificationRunning: Sendable {
  func run(
    scope: TaskEvidenceScope,
    project: RegisteredProject,
    workingDirectory: RegisteredRoot
  ) async throws -> [PipelineVerificationEvidence]
}

public struct ClosureTaskPipelineVerificationRunner: TaskPipelineVerificationRunning {
  private let body:
    @Sendable (TaskEvidenceScope, RegisteredProject, RegisteredRoot) async throws
      -> [PipelineVerificationEvidence]

  public init(
    _ body:
      @escaping @Sendable (
        TaskEvidenceScope,
        RegisteredProject,
        RegisteredRoot
      ) async throws -> [PipelineVerificationEvidence]
  ) {
    self.body = body
  }

  public func run(
    scope: TaskEvidenceScope,
    project: RegisteredProject,
    workingDirectory: RegisteredRoot
  ) async throws -> [PipelineVerificationEvidence] {
    try await body(scope, project, workingDirectory)
  }
}

public protocol TaskPipelineSupervisorReviewing: Sendable {
  func review(
    _ checkpoint: SupervisorCheckpoint,
    root: RegisteredRoot,
    model: String,
    effort: String
  ) async throws -> SupervisorDecision
}

extension CodexSupervisorRuntime: TaskPipelineSupervisorReviewing {}

public struct TaskPipelinePolicyContext: Sendable {
  public let scope: TaskEvidenceScope
  public let project: RegisteredProject
  public let baseline: GitBaselineEvidence
  public let final: GitFinalEvidence
  public let verification: [PipelineVerificationEvidence]

  public init(
    scope: TaskEvidenceScope,
    project: RegisteredProject,
    baseline: GitBaselineEvidence,
    final: GitFinalEvidence,
    verification: [PipelineVerificationEvidence]
  ) {
    self.scope = scope
    self.project = project
    self.baseline = baseline
    self.final = final
    self.verification = verification
  }
}

public protocol TaskPipelinePolicyEvaluating: Sendable {
  func evaluate(_ context: TaskPipelinePolicyContext) async throws -> PolicyEvidence
}

public struct ClosureTaskPipelinePolicyEvaluator: TaskPipelinePolicyEvaluating {
  private let body: @Sendable (TaskPipelinePolicyContext) async throws -> PolicyEvidence

  public init(
    _ body: @escaping @Sendable (TaskPipelinePolicyContext) async throws -> PolicyEvidence
  ) {
    self.body = body
  }

  public func evaluate(_ context: TaskPipelinePolicyContext) async throws -> PolicyEvidence {
    try await body(context)
  }
}

public enum TaskPipelineOrchestratorError: Error, Equatable, Sendable {
  case durableRuntimeRequired
  case unknownProject(ProjectID)
  case scopeMismatch
  case stageMismatch(PipelineStage)
  case verificationMismatch
  case supervisorRejected(SupervisorDecisionKind)
}

public actor TaskPipelineOrchestrator: TaskPipelineLifecycle {
  private let preflight: PipelinePreflightStore
  private let artifacts: PipelineArtifactStore
  private let finalizer: PipelineFinalizer
  private let coordinator: TaskCoordinator
  private let projects: any TaskPipelineProjectProviding
  private let git: any TaskPipelineGitEvidenceCollecting
  private let verification: any TaskPipelineVerificationRunning
  private let supervisor: any TaskPipelineSupervisorReviewing
  private let policy: any TaskPipelinePolicyEvaluating

  public init(
    preflight: PipelinePreflightStore,
    artifacts: PipelineArtifactStore,
    finalizer: PipelineFinalizer,
    coordinator: TaskCoordinator,
    projects: any TaskPipelineProjectProviding,
    git: any TaskPipelineGitEvidenceCollecting,
    verification: any TaskPipelineVerificationRunning,
    supervisor: any TaskPipelineSupervisorReviewing,
    policy: any TaskPipelinePolicyEvaluating
  ) {
    self.preflight = preflight
    self.artifacts = artifacts
    self.finalizer = finalizer
    self.coordinator = coordinator
    self.projects = projects
    self.git = git
    self.verification = verification
    self.supervisor = supervisor
    self.policy = policy
  }

  public func prepareForLegacyTurnStart(taskID _: TaskID, submission _: TaskSubmission) throws {
    throw TaskPipelineOrchestratorError.durableRuntimeRequired
  }

  public func prepareForTurnStart(_ context: TaskPipelinePreStartContext) async throws {
    guard try await projects.project(for: context.submission.projectID) != nil else {
      throw TaskPipelineOrchestratorError.unknownProject(context.submission.projectID)
    }
    let baseline = try await git.captureBaseline(
      projectIdentifier: context.submission.projectID.rawValue
    )
    try await preflight.storeBaseline(context: context, baseline: baseline)
  }

  public func recordStartedTurn(_ context: TaskPipelineStartedContext) async throws {
    try await preflight.recordStartedTurn(context)
  }

  public func finalizeVerifyingTask(_ context: TaskPipelineVerifyingContext) async throws {
    let scope = try makeScope(context.projection)
    do {
      try await finalize(context, scope: scope)
    } catch {
      try await failSagaIfActive(scope)
      throw error
    }
  }

  public func discardTaskState(taskID: TaskID) async throws {
    try await failCurrentSagaIfActive(taskID: taskID)
    try await preflight.discard(taskID: taskID)
  }

  public func recoverPendingPreflights() async throws -> [TaskProjection] {
    var recovered: [TaskProjection] = []
    for record in try await preflight.allRecords() {
      let current = try await coordinator.task(record.key.taskID)
      if current.aggregate.phase.isTerminal || current.aggregate.phase == .suspended {
        try await discardTaskState(taskID: record.key.taskID)
        continue
      }
      guard current.aggregate.phase == .verifying,
        let binding = current.aggregate.binding,
        binding.threadID == record.key.threadID,
        binding.turnGeneration == record.key.generation,
        binding.turnID == record.turnID
      else { continue }
      do {
        try await finalizeVerifyingTask(TaskPipelineVerifyingContext(projection: current))
        recovered.append(try await coordinator.task(record.key.taskID))
      } catch {
        recovered.append(
          try await coordinator.failPipelineRecovery(
            taskID: record.key.taskID,
            expectedBinding: binding,
            expectedSequence: current.lastSequence
          )
        )
      }
    }
    return recovered
  }

  private func finalize(
    _ context: TaskPipelineVerifyingContext,
    scope: TaskEvidenceScope
  ) async throws {
    let task = context.projection
    guard let binding = task.aggregate.binding else {
      throw TaskPipelineOrchestratorError.scopeMismatch
    }
    let record = try await preflight.startedRecord(taskID: task.aggregate.id, binding: binding)
    guard record.key.projectID == task.aggregate.submission.projectID else {
      throw TaskPipelineOrchestratorError.scopeMismatch
    }
    let project = try await requiredProject(scope.projectID)
    let root = try executionRoot(project: project, baseline: record.baseline)
    var saga = try await artifacts.begin(scope)
    saga = try await persistBaseline(record.baseline, scope: scope, saga: saga)
    saga = try await persistTurnCompletion(scope: scope, saga: saga)
    let finalResult = try await persistFinalGit(
      baseline: record.baseline,
      scope: scope,
      saga: saga
    )
    saga = finalResult.saga
    let verificationResult = try await persistVerification(
      scope: scope,
      project: project,
      root: root,
      saga: saga
    )
    saga = verificationResult.saga
    let supervisorResult = try await persistSupervisor(
      scope: scope,
      task: task,
      root: root,
      final: finalResult.evidence,
      verification: verificationResult.evidence,
      saga: saga
    )
    guard supervisorResult.saga.stage == .supervisorReviewed else {
      throw TaskPipelineOrchestratorError.stageMismatch(supervisorResult.saga.stage)
    }
    let policyEvidence = try await policy.evaluate(
      TaskPipelinePolicyContext(
        scope: scope,
        project: project,
        baseline: record.baseline,
        final: finalResult.evidence,
        verification: verificationResult.evidence
      )
    )
    let report = try makeReport(
      scope: scope,
      task: task,
      project: project,
      baseline: record.baseline,
      final: finalResult.evidence,
      verification: verificationResult.evidence,
      supervisorDecision: supervisorResult.evidence.decision,
      policy: policyEvidence,
      startedAt: record.capturedAt,
      completedAt: Date()
    )
    _ = try await finalizer.finalize(scope: scope, report: report)
    try await preflight.discard(taskID: scope.taskID)
  }

  private func makeScope(_ task: TaskProjection) throws -> TaskEvidenceScope {
    guard task.aggregate.phase == .verifying, let binding = task.aggregate.binding,
      let generation = Int64(exactly: binding.turnGeneration)
    else { throw TaskPipelineOrchestratorError.scopeMismatch }
    return try TaskEvidenceScope(
      taskID: task.aggregate.id,
      projectID: task.aggregate.submission.projectID,
      threadID: binding.threadID,
      turnID: binding.turnID,
      generation: generation,
      eventSequence: task.lastSequence
    )
  }

  private func failSagaIfActive(_ scope: TaskEvidenceScope) async throws {
    guard let current = try await artifacts.finalization(for: scope.taskID),
      current.scope == scope, !current.stage.isTerminal
    else { return }
    _ = try await artifacts.advance(scope, to: .failed)
  }

  private func failCurrentSagaIfActive(taskID: TaskID) async throws {
    guard let current = try await artifacts.finalization(for: taskID),
      !current.stage.isTerminal
    else { return }
    _ = try await artifacts.advance(current.scope, to: .failed)
  }

  private func requiredProject(_ id: ProjectID) async throws -> RegisteredProject {
    guard let project = try await projects.project(for: id) else {
      throw TaskPipelineOrchestratorError.unknownProject(id)
    }
    return project
  }

  private func executionRoot(
    project: RegisteredProject,
    baseline: GitBaselineEvidence
  ) throws -> RegisteredRoot {
    let repositoryRoot = project.repositoryRoot
    guard repositoryRoot.canonicalPath == baseline.canonicalRootPath,
      repositoryRoot.identity.device == baseline.rootIdentity?.device,
      repositoryRoot.identity.inode == baseline.rootIdentity?.inode
    else { throw TaskPipelineOrchestratorError.scopeMismatch }
    return project.primaryRoot
  }

  private func persistBaseline(
    _ baseline: GitBaselineEvidence,
    scope: TaskEvidenceScope,
    saga: PipelineFinalizationRecord
  ) async throws -> PipelineFinalizationRecord {
    guard saga.stage == .created || saga.stage == .baselineCaptured else { return saga }
    if saga.stage == .baselineCaptured { return saga }
    _ = try await artifacts.store(scope: scope, kind: .gitBaseline, payload: baseline)
    return try await artifacts.advance(scope, to: .baselineCaptured)
  }

  private func persistTurnCompletion(
    scope: TaskEvidenceScope,
    saga: PipelineFinalizationRecord
  ) async throws -> PipelineFinalizationRecord {
    guard saga.stage == .baselineCaptured || saga.stage == .turnCompleted else { return saga }
    if saga.stage == .turnCompleted { return saga }
    return try await artifacts.advance(scope, to: .turnCompleted)
  }

  private func persistFinalGit(
    baseline: GitBaselineEvidence,
    scope: TaskEvidenceScope,
    saga: PipelineFinalizationRecord
  ) async throws -> (saga: PipelineFinalizationRecord, evidence: GitFinalEvidence) {
    if saga.stage == .turnCompleted {
      let final = try await git.captureFinal(
        projectIdentifier: scope.projectID.rawValue,
        baseline: baseline
      )
      _ = try await artifacts.store(scope: scope, kind: .gitFinal, payload: final)
      return (try await artifacts.advance(scope, to: .gitFinalCaptured), final)
    }
    guard
      let final: GitFinalEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .gitFinal
      )
    else { throw TaskPipelineOrchestratorError.stageMismatch(saga.stage) }
    return (saga, final)
  }

  private func persistVerification(
    scope: TaskEvidenceScope,
    project: RegisteredProject,
    root: RegisteredRoot,
    saga: PipelineFinalizationRecord
  ) async throws -> (saga: PipelineFinalizationRecord, evidence: [PipelineVerificationEvidence]) {
    if saga.stage == .gitFinalCaptured {
      let evidence = try await verificationEvidence(scope: scope, project: project, root: root)
      for item in evidence {
        _ = try await artifacts.store(
          scope: scope,
          kind: .verification(item.id.rawValue),
          payload: item
        )
      }
      return (try await artifacts.advance(scope, to: .verificationCompleted), evidence)
    }
    let evidence = try await storedVerification(scope: scope)
    return (saga, evidence)
  }

  private func verificationEvidence(
    scope: TaskEvidenceScope,
    project: RegisteredProject,
    root: RegisteredRoot
  ) async throws -> [PipelineVerificationEvidence] {
    guard !project.verificationCommands.isEmpty else {
      return [try .notConfigured()]
    }
    let results = try await verification.run(
      scope: scope,
      project: project,
      workingDirectory: root
    )
    let expected = Set(
      project.verificationCommands.map(VerificationCommandIdentifier.init(command:)))
    let actual = Set(results.map(\.id))
    guard results.count == actual.count, actual == expected else {
      throw TaskPipelineOrchestratorError.verificationMismatch
    }
    return results.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  private func storedVerification(scope: TaskEvidenceScope) async throws
    -> [PipelineVerificationEvidence]
  {
    let summaries = try await artifacts.artifacts(for: scope)
    var values: [PipelineVerificationEvidence] = []
    for summary in summaries {
      guard case .verification = summary.kind else { continue }
      guard
        let item: PipelineVerificationEvidence = try await artifacts.trustedPayload(
          for: scope,
          kind: summary.kind
        )
      else { throw TaskPipelineOrchestratorError.verificationMismatch }
      values.append(item)
    }
    guard !values.isEmpty else { throw TaskPipelineOrchestratorError.verificationMismatch }
    return values.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  private func persistSupervisor(
    scope: TaskEvidenceScope,
    task: TaskProjection,
    root: RegisteredRoot,
    final: GitFinalEvidence,
    verification: [PipelineVerificationEvidence],
    saga: PipelineFinalizationRecord
  ) async throws -> (saga: PipelineFinalizationRecord, evidence: PipelineSupervisorFinalEvidence) {
    if saga.stage == .verificationCompleted {
      let checkpoint = try makeCheckpoint(
        scope: scope,
        task: task,
        final: final,
        verification: verification
      )
      let decision = try await supervisor.review(
        checkpoint,
        root: root,
        model: task.aggregate.submission.supervisor.model,
        effort: task.aggregate.submission.supervisor.effort
      )
      guard decision.decision == .finalAccept else {
        throw TaskPipelineOrchestratorError.supervisorRejected(decision.decision)
      }
      let evidence = try PipelineSupervisorFinalEvidence(
        scope: scope,
        checkpointStage: .final,
        decision: decision
      )
      _ = try await artifacts.store(
        scope: scope,
        kind: .supervisorFinalDecision,
        payload: evidence
      )
      return (try await artifacts.advance(scope, to: .supervisorReviewed), evidence)
    }
    guard
      let evidence: PipelineSupervisorFinalEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .supervisorFinalDecision
      )
    else { throw TaskPipelineOrchestratorError.stageMismatch(saga.stage) }
    return (saga, evidence)
  }

  private func makeCheckpoint(
    scope: TaskEvidenceScope,
    task: TaskProjection,
    final: GitFinalEvidence,
    verification: [PipelineVerificationEvidence]
  ) throws -> SupervisorCheckpoint {
    let sequence = UInt64(scope.eventSequence)
    let contract = try Self.encodedContract(task.aggregate.submission.contract)
    return try SupervisorCheckpoint(
      sequence: sequence,
      taskID: scope.taskID.rawValue,
      turnID: scope.turnID.rawValue,
      stage: .final,
      triggers: [.completionClaimed],
      content: SupervisorCheckpointContent(
        taskContract: contract,
        projectRulePaths: task.aggregate.submission.contract.allowedPaths
          + task.aggregate.submission.contract.forbiddenPaths,
        executionModel: task.aggregate.submission.execution.model,
        executionEffort: task.aggregate.submission.execution.effort,
        recentEvents: ["Codex turn completed and entered deterministic verification."],
        changedFiles: Array(Set(final.changedFiles + final.untrackedFiles)).sorted(),
        gitDiffSummary: final.diffStat.isEmpty ? "No Git diff stat recorded." : final.diffStat,
        verificationResults: verification.map(Self.supervisorVerification),
        remainingAutomaticSteers: 0
      )
    )
  }

  private func makeReport(
    scope: TaskEvidenceScope,
    task: TaskProjection,
    project: RegisteredProject,
    baseline: GitBaselineEvidence,
    final: GitFinalEvidence,
    verification: [PipelineVerificationEvidence],
    supervisorDecision: SupervisorDecision,
    policy: PolicyEvidence,
    startedAt: Date,
    completedAt: Date
  ) throws -> FinalReportDocument {
    guard supervisorDecision.decision == .finalAccept else {
      throw TaskPipelineOrchestratorError.supervisorRejected(supervisorDecision.decision)
    }
    return try ReportBuilder().build(
      from: FinalReportInput(
        taskID: scope.taskID.rawValue,
        status: .completed,
        project: project.name,
        appServer: AppServerEvidence(
          threadID: scope.threadID.rawValue,
          model: task.aggregate.submission.execution.model,
          effort: task.aggregate.submission.execution.effort,
          terminalState: .completed,
          startedAt: startedAt,
          completedAt: completedAt
        ),
        git: GitEvidence(
          baselineCaptured: true,
          finalStateCaptured: true,
          dirtyAtStart: baseline.status.isDirty,
          changedFiles: Self.changedFiles(final),
          diffStat: final.diffStat,
          commit: final.status.headCommit
        ),
        verification: verification.map(\.reportingEvidence),
        supervisor: SupervisorEvidence(
          model: task.aggregate.submission.supervisor.model,
          effort: task.aggregate.submission.supervisor.effort,
          checks: 1,
          steers: 0,
          finalDecision: .finalAccept
        ),
        policy: policy
      )
    )
  }

  private static func supervisorVerification(
    _ evidence: PipelineVerificationEvidence
  ) -> SupervisorVerificationResult {
    let item = evidence.reportingEvidence
    let outcome: SupervisorVerificationOutcome
    switch item.status {
    case .passed: outcome = .passed
    case .failed: outcome = .failed
    case .unavailable: outcome = .skipped
    }
    return SupervisorVerificationResult(
      name: item.name,
      outcome: outcome,
      summary: item.unavailableReason ?? "Exit code: \(item.exitCode.map(String.init) ?? "none")."
    )
  }

  private static func changedFiles(_ final: GitFinalEvidence) -> [GitChangedFileEvidence] {
    let untracked = Set(final.untrackedFiles)
    return Array(Set(final.changedFiles + final.untrackedFiles)).sorted().map { path in
      let entry = final.status.entries.first { $0.path == path }
      return GitChangedFileEvidence(
        relativePath: path,
        change: changeKind(entry: entry, untracked: untracked.contains(path))
      )
    }
  }

  private static func changeKind(entry: GitFileChange?, untracked: Bool) -> GitChangeKind {
    if untracked { return .untracked }
    guard let entry else { return .modified }
    if entry.kind == .renamedOrCopied { return .renamed }
    if entry.indexStatus == "D" || entry.workTreeStatus == "D" { return .deleted }
    if entry.indexStatus == "A" || entry.workTreeStatus == "A" { return .added }
    return .modified
  }

  private static func encodedContract(_ contract: TaskContract) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(contract), as: UTF8.self)
  }
}
