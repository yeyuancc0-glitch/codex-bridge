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
  case supervisionScopeMissing(TaskID)
  case stageMismatch(PipelineStage)
  case verificationMismatch
  case supervisorRejected(SupervisorDecisionKind)
  case deterministicFallbackNotAuthorized
  case policyRejected
  case supervisorActionScopeMismatch
  case supervisorActionUnresolved
}

public actor TaskPipelineOrchestrator: TaskPipelineLifecycle {
  private enum CompletionReview: Equatable, Sendable {
    case supervisor(SupervisorDecision)
    case deterministicPolicy(
      policy: PolicyEvidence,
      userOverride: UserCompletionOverride,
      digest: String
    )
  }

  private let preflight: PipelinePreflightStore
  private let artifacts: PipelineArtifactStore
  private let finalizer: PipelineFinalizer
  private let coordinator: TaskCoordinator
  private let projects: any TaskPipelineProjectProviding
  private let git: any TaskPipelineGitEvidenceCollecting
  private let verification: any TaskPipelineVerificationRunning
  private let supervisor: any TaskPipelineSupervisorReviewing
  private let policy: any TaskPipelinePolicyEvaluating
  private let supervision: DurableSupervisionLedger?

  public init(
    preflight: PipelinePreflightStore,
    artifacts: PipelineArtifactStore,
    finalizer: PipelineFinalizer,
    coordinator: TaskCoordinator,
    projects: any TaskPipelineProjectProviding,
    git: any TaskPipelineGitEvidenceCollecting,
    verification: any TaskPipelineVerificationRunning,
    supervisor: any TaskPipelineSupervisorReviewing,
    policy: any TaskPipelinePolicyEvaluating,
    supervision: DurableSupervisionLedger? = nil
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
    self.supervision = supervision
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
    guard let supervision else { return }
    let scope = try supervisionScope(
      taskID: context.preStart.taskID,
      submission: context.preStart.submission,
      binding: context.binding
    )
    _ = try await supervision.begin(
      scope: scope,
      configuration: SupervisorGuardConfiguration(
        deterministicFallbackAuthorized:
          !context.preStart.submission.supervisor.enabled
          && context.preStart.submission.supervisor.deterministicFallbackAuthorized
      )
    )
  }

  public func recordSemanticObservation(_ context: TaskPipelineSemanticContext) async throws {
    guard let supervision else { return }
    guard context.projection.aggregate.binding == context.binding else {
      throw TaskPipelineOrchestratorError.scopeMismatch
    }
    let scope = try supervisionScope(
      taskID: context.projection.aggregate.id,
      submission: context.projection.aggregate.submission,
      binding: context.binding
    )
    guard let state = try await supervision.state(for: scope) else {
      throw TaskPipelineOrchestratorError.supervisionScopeMissing(scope.taskID)
    }
    let checkpoint = try makeProgressCheckpoint(
      context: context,
      state: state.state,
      configuration: state.configuration
    )
    _ = try await supervision.appendCheckpoint(scope: scope, checkpoint: checkpoint)
    guard context.projection.aggregate.submission.supervisor.enabled else { return }
    let project = try await requiredProject(scope.projectID)
    try project.validateCurrentRoots()
    let decision = try await supervisor.review(
      checkpoint,
      root: project.primaryRoot,
      model: context.projection.aggregate.submission.supervisor.model,
      effort: context.projection.aggregate.submission.supervisor.effort
    )
    let review = try await supervision.appendReview(
      scope: scope,
      position: SupervisorReviewPosition(checkpointSequence: checkpoint.sequence, attempt: 0),
      result: .decision(decision),
      taskEventSequence: context.projection.lastSequence
    )
    try await executeSupervisorAction(review.action)
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

  @discardableResult
  public func recoverPendingSupervisorActions(limit: Int = 100) async throws -> Int {
    guard let supervision else { return 0 }
    let actions = try await supervision.pendingActions(limit: limit)
    var applied = 0
    for action in actions {
      try await executeSupervisorAction(action)
      applied += 1
    }
    return applied
  }

  public func recoverPendingPreflights() async throws -> [TaskProjection] {
    _ = try await recoverPendingSupervisorActions(limit: DurableSupervisionLedger.maximumQueryLimit)
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
    try await requireNoAmbiguousSupervisorAction(for: scope)
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
    let policyEvidence = try await policy.evaluate(
      TaskPipelinePolicyContext(
        scope: scope,
        project: project,
        baseline: record.baseline,
        final: finalResult.evidence,
        verification: verificationResult.evidence
      )
    )
    let reviewResult = try await persistCompletionReview(
      scope: scope,
      task: task,
      root: root,
      final: finalResult.evidence,
      verification: verificationResult.evidence,
      policy: policyEvidence,
      saga: saga
    )
    guard reviewResult.saga.stage == .supervisorReviewed else {
      throw TaskPipelineOrchestratorError.stageMismatch(reviewResult.saga.stage)
    }
    let reportPolicy: PolicyEvidence
    let supervisorDecision: SupervisorDecision?
    let userOverride: UserCompletionOverride?
    switch reviewResult.review {
    case .supervisor(let decision):
      reportPolicy = policyEvidence
      supervisorDecision = decision
      userOverride = nil
    case .deterministicPolicy(let storedPolicy, let override, _):
      reportPolicy = storedPolicy
      supervisorDecision = nil
      userOverride = override
    }
    let report = try makeReport(
      scope: scope,
      task: task,
      project: project,
      baseline: record.baseline,
      final: finalResult.evidence,
      verification: verificationResult.evidence,
      supervisorDecision: supervisorDecision,
      policy: reportPolicy,
      userOverride: userOverride,
      startedAt: record.capturedAt,
      completedAt: Date()
    )
    _ = try await finalizer.finalize(scope: scope, report: report)
    if let supervision {
      _ = try await supervision.close(scope: try durableScope(from: scope))
    }
    try await preflight.discard(taskID: scope.taskID)
  }

  private func persistCompletionReview(
    scope: TaskEvidenceScope,
    task: TaskProjection,
    root: RegisteredRoot,
    final: GitFinalEvidence,
    verification: [PipelineVerificationEvidence],
    policy: PolicyEvidence,
    saga: PipelineFinalizationRecord
  ) async throws -> (saga: PipelineFinalizationRecord, review: CompletionReview) {
    if task.aggregate.submission.supervisor.enabled {
      let result = try await persistSupervisor(
        scope: scope,
        task: task,
        root: root,
        final: final,
        verification: verification,
        saga: saga
      )
      return (result.saga, .supervisor(result.evidence.decision))
    }
    guard task.aggregate.submission.supervisor.deterministicFallbackAuthorized else {
      throw TaskPipelineOrchestratorError.deterministicFallbackNotAuthorized
    }
    if saga.stage == .verificationCompleted {
      guard policy.evaluationCompleted, policy.unresolvedBlockers.isEmpty else {
        throw TaskPipelineOrchestratorError.policyRejected
      }
      let userOverride = UserCompletionOverride(
        decisionID: "policy:\(scope.taskID.rawValue):\(scope.generation)",
        reason: "用户已选择在语义监督不可用时使用确定性 Policy Engine。",
        confirmedAt: Date()
      )
      let evidence = try PipelineDeterministicPolicyFinalEvidence(
        scope: scope,
        policy: policy,
        userOverride: userOverride
      )
      _ = try await artifacts.store(
        scope: scope,
        kind: .supervisorFinalDecision,
        payload: evidence
      )
      return (
        try await artifacts.advance(scope, to: .supervisorReviewed),
        .deterministicPolicy(
          policy: policy,
          userOverride: userOverride,
          digest: evidence.decisionDigest
        )
      )
    }
    if let evidence = try await artifacts.completionEvidence(for: scope)?.deterministicPolicy {
      return (
        saga,
        .deterministicPolicy(
          policy: evidence.policy,
          userOverride: evidence.userOverride,
          digest: evidence.decisionDigest
        )
      )
    }
    throw TaskPipelineOrchestratorError.stageMismatch(saga.stage)
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

  private func durableScope(from scope: TaskEvidenceScope) throws -> DurableSupervisionScope {
    try DurableSupervisionScope(
      taskID: scope.taskID,
      projectID: scope.projectID,
      threadID: scope.threadID,
      turnID: scope.turnID,
      generation: scope.generation
    )
  }

  private func requireNoAmbiguousSupervisorAction(for scope: TaskEvidenceScope) async throws {
    guard let supervision else { return }
    let durable = try durableScope(from: scope)
    let ambiguous = try await supervision.ambiguousActions(
      limit: DurableSupervisionLedger.maximumQueryLimit
    )
    guard !ambiguous.contains(where: { $0.scope == durable }) else {
      throw TaskPipelineOrchestratorError.supervisorActionUnresolved
    }
  }

  private func executeSupervisorAction(
    _ action: DurableSupervisorActionRecord?
  ) async throws {
    guard let action, action.state == .pending, let supervision else { return }
    let attempt = try await supervision.beginActionAttempt(id: action.id)
    let current = try await coordinator.task(attempt.scope.taskID)
    guard current.aggregate.phase == .running,
      current.aggregate.submission.projectID == attempt.scope.projectID,
      let binding = current.aggregate.binding,
      binding.threadID == attempt.scope.threadID,
      binding.turnID == attempt.scope.turnID,
      Int64(exactly: binding.turnGeneration) == attempt.scope.generation,
      current.lastSequence == attempt.taskEventSequence
    else {
      throw TaskPipelineOrchestratorError.supervisorActionScopeMismatch
    }
    switch attempt.kind {
    case .steer:
      _ = try await coordinator.steerWithResult(
        taskID: attempt.scope.taskID,
        expectedTurnID: binding.turnID,
        expectedSequence: attempt.taskEventSequence,
        prompt: attempt.instruction
      )
    case .suspend:
      _ = try await coordinator.suspendWithResult(
        taskID: attempt.scope.taskID,
        expectedTurnID: binding.turnID,
        expectedSequence: attempt.taskEventSequence,
        reason: attempt.instruction
      )
    case .interrupt:
      _ = try await coordinator.interruptWithResult(
        taskID: attempt.scope.taskID,
        expectedTurnID: binding.turnID,
        expectedSequence: attempt.taskEventSequence,
        reason: attempt.instruction
      )
    }
    _ = try await supervision.markActionApplied(id: attempt.id)
  }

  private func supervisionScope(
    taskID: TaskID,
    submission: TaskSubmission,
    binding: ExecutionBinding
  ) throws -> DurableSupervisionScope {
    guard let generation = Int64(exactly: binding.turnGeneration) else {
      throw TaskPipelineOrchestratorError.scopeMismatch
    }
    return try DurableSupervisionScope(
      taskID: taskID,
      projectID: submission.projectID,
      threadID: binding.threadID,
      turnID: binding.turnID,
      generation: generation
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
    try project.validateCurrentRoots()
    let repositoryRoot = project.repositoryRoot
    guard repositoryRoot.canonicalPath == baseline.canonicalRootPath,
      repositoryRoot.identity.posixDeviceValue == baseline.rootIdentity?.device,
      repositoryRoot.identity.posixInodeValue == baseline.rootIdentity?.inode
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
      if let supervision {
        let durableScope = try durableScope(from: scope)
        _ = try await supervision.appendReview(
          scope: durableScope,
          position: SupervisorReviewPosition(checkpointSequence: checkpoint.sequence, attempt: 0),
          result: .decision(decision),
          taskEventSequence: scope.eventSequence
        )
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

  private func makeProgressCheckpoint(
    context: TaskPipelineSemanticContext,
    state: SupervisorGuardState,
    configuration: SupervisorGuardConfiguration
  ) throws -> SupervisorCheckpoint {
    let observation = context.observation
    let details = Self.progressDetails(observation)
    let contract = try Self.encodedContract(context.projection.aggregate.submission.contract)
    let remainingSteers = max(0, configuration.maximumSteersPerTask - state.taskSteerCount)
    return try SupervisorCheckpoint(
      sequence: UInt64(context.projection.lastSequence),
      taskID: context.projection.aggregate.id.rawValue,
      turnID: context.binding.turnID.rawValue,
      stage: .progress,
      triggers: [details.trigger],
      content: SupervisorCheckpointContent(
        taskContract: contract,
        projectRulePaths: context.projection.aggregate.submission.contract.allowedPaths
          + context.projection.aggregate.submission.contract.forbiddenPaths,
        executionModel: context.projection.aggregate.submission.execution.model,
        executionEffort: context.projection.aggregate.submission.execution.effort,
        currentPlan: details.currentPlan,
        recentEvents: [details.event],
        commandResults: details.commandResults,
        remainingAutomaticSteers: remainingSteers
      )
    )
  }

  private static func progressDetails(
    _ observation: TaskSemanticExecutionObservation
  ) -> (
    trigger: SupervisorCheckpointTrigger,
    currentPlan: [String],
    commandResults: [SupervisorCommandResult],
    event: String
  ) {
    switch observation.evidence {
    case .planChanged(let plan):
      return (
        .planChanged,
        plan.steps.map { "\($0.status.rawValue): \($0.text)" },
        [],
        "Execution plan changed."
      )
    case .commandCompleted(let command):
      let trigger: SupervisorCheckpointTrigger =
        command.status == .failed
        ? .commandFailed : .manual
      return (
        trigger,
        [],
        [
          SupervisorCommandResult(
            displayCommand: command.displayCommand,
            exitCode: command.exitCode ?? -1
          )
        ],
        "Command \(command.status.rawValue): \(command.itemID)."
      )
    case .fileChangeCompleted(let file):
      return (
        file.changeCount > 0 ? .firstFileModification : .manual,
        [],
        [],
        "File-change item \(file.status.rawValue): \(file.itemID), changes: \(file.changeCount)."
      )
    }
  }

  private func makeReport(
    scope: TaskEvidenceScope,
    task: TaskProjection,
    project: RegisteredProject,
    baseline: GitBaselineEvidence,
    final: GitFinalEvidence,
    verification: [PipelineVerificationEvidence],
    supervisorDecision: SupervisorDecision?,
    policy: PolicyEvidence,
    userOverride: UserCompletionOverride?,
    startedAt: Date,
    completedAt: Date
  ) throws -> FinalReportDocument {
    if let supervisorDecision, supervisorDecision.decision != .finalAccept {
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
        supervisor: supervisorDecision.map { _ in
          SupervisorEvidence(
            model: task.aggregate.submission.supervisor.model,
            effort: task.aggregate.submission.supervisor.effort,
            checks: 1,
            steers: 0,
            finalDecision: .finalAccept
          )
        },
        policy: policy,
        userOverride: userOverride
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
