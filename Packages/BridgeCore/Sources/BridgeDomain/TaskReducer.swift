import Foundation

public enum TaskEvent: Codable, Equatable, Sendable {
  case localApprovalRequested
  case localApprovalResolved(approved: Bool)
  case preparationStarted
  case turnStarted(ExecutionBinding)
  case codexApprovalEvidenceRecorded(CodexApprovalEvidence)
  case codexApprovalRequested(ApprovalID)
  case codexApprovalResolutionRequested(ApprovalID, approved: Bool)
  case codexApprovalApproved(ApprovalID)
  case codexApprovalDenied(ApprovalID, StopIntent)
  case supervisionStarted
  case correctionStarted
  case supervisorActivityFinished
  case stopRequested(StopIntent)
  case turnStopped
  case turnCompleted
  case repairRequested
  case finalReportStored(reference: String)
  case completionRecorded
  case failureRecorded(reason: String)
  case resumeRequested
  case recoveryStarted
  case recoveryAmbiguous
  case recoveryResolved(to: TaskPhase)

  public var kind: String {
    switch self {
    case .localApprovalRequested: "localApprovalRequested"
    case .localApprovalResolved: "localApprovalResolved"
    case .preparationStarted: "preparationStarted"
    case .turnStarted: "turnStarted"
    case .codexApprovalEvidenceRecorded: "codexApprovalEvidenceRecorded"
    case .codexApprovalRequested: "codexApprovalRequested"
    case .codexApprovalResolutionRequested: "codexApprovalResolutionRequested"
    case .codexApprovalApproved: "codexApprovalApproved"
    case .codexApprovalDenied: "codexApprovalDenied"
    case .supervisionStarted: "supervisionStarted"
    case .correctionStarted: "correctionStarted"
    case .supervisorActivityFinished: "supervisorActivityFinished"
    case .stopRequested: "stopRequested"
    case .turnStopped: "turnStopped"
    case .turnCompleted: "turnCompleted"
    case .repairRequested: "repairRequested"
    case .finalReportStored: "finalReportStored"
    case .completionRecorded: "completionRecorded"
    case .failureRecorded: "failureRecorded"
    case .resumeRequested: "resumeRequested"
    case .recoveryStarted: "recoveryStarted"
    case .recoveryAmbiguous: "recoveryAmbiguous"
    case .recoveryResolved: "recoveryResolved"
    }
  }
}

public enum TaskTransitionError: Error, Codable, Equatable, Sendable {
  case terminalState(TaskPhase)
  case invalidTransition(phase: TaskPhase, event: String)
  case invalidSubmission(field: String)
  case invalidBinding(reason: String)
  case approvalAlreadyPending(ApprovalID)
  case approvalNotPending(ApprovalID)
  case stopAlreadyRequested
  case stopIntentRequired
  case reportRequired
  case invalidReportReference
  case invalidRecoveryTarget(TaskPhase)
}

public enum TaskReducer {
  public static func reduce(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    guard !aggregate.phase.isTerminal else {
      throw TaskTransitionError.terminalState(aggregate.phase)
    }

    switch event {
    case .localApprovalRequested:
      return try requestLocalApproval(aggregate, event: event)
    case .localApprovalResolved(let approved):
      return try resolveLocalApproval(aggregate, approved: approved, event: event)
    case .preparationStarted:
      return try startPreparation(aggregate, event: event)
    case .turnStarted(let binding):
      return try startTurn(aggregate, binding: binding, event: event)
    case .codexApprovalEvidenceRecorded(let evidence):
      return try recordCodexApprovalEvidence(aggregate, evidence: evidence, event: event)
    case .codexApprovalRequested(let approvalID):
      return try requestCodexApproval(aggregate, approvalID: approvalID, event: event)
    case .codexApprovalResolutionRequested(let approvalID, _):
      return try reserveCodexApproval(aggregate, approvalID: approvalID, event: event)
    case .codexApprovalApproved(let approvalID):
      return try approveCodexApproval(aggregate, approvalID: approvalID, event: event)
    case .codexApprovalDenied(let approvalID, let intent):
      return try denyCodexApproval(
        aggregate,
        approvalID: approvalID,
        intent: intent,
        event: event
      )
    case .supervisionStarted:
      return try setActivity(aggregate, activity: .supervising, event: event)
    case .correctionStarted:
      return try setActivity(aggregate, activity: .correcting, event: event)
    case .supervisorActivityFinished:
      return try finishActivity(aggregate, event: event)
    case .stopRequested(let intent):
      return try requestStop(aggregate, intent: intent, event: event)
    case .turnStopped:
      return try stopTurn(aggregate, event: event)
    case .turnCompleted:
      return try completeTurn(aggregate, event: event)
    case .repairRequested:
      return try requestRepair(aggregate, event: event)
    case .finalReportStored(let reference):
      return try storeReport(aggregate, reference: reference, event: event)
    case .completionRecorded:
      return try recordCompletion(aggregate, event: event)
    case .failureRecorded(let reason):
      return try recordFailure(aggregate, reason: reason, event: event)
    case .resumeRequested:
      return try resume(aggregate, event: event)
    case .recoveryStarted:
      return try startRecovery(aggregate, event: event)
    case .recoveryAmbiguous:
      return try markRecoveryAmbiguous(aggregate, event: event)
    case .recoveryResolved(let target):
      return try resolveRecovery(aggregate, target: target, event: event)
    }
  }
}

extension TaskReducer {
  fileprivate static func requestLocalApproval(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.draft], event: event)
    try validate(aggregate.submission)

    var next = aggregate
    next.phase = .awaitingLocalApproval
    return next
  }

  fileprivate static func resolveLocalApproval(
    _ aggregate: TaskAggregate,
    approved: Bool,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.awaitingLocalApproval], event: event)

    var next = aggregate
    next.phase = approved ? .preparing : .rejected
    return next
  }

  fileprivate static func startPreparation(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.draft], event: event)
    try validate(aggregate.submission)

    var next = aggregate
    next.phase = .preparing
    return next
  }

  fileprivate static func startTurn(
    _ aggregate: TaskAggregate,
    binding: ExecutionBinding,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.preparing], event: event)
    try validate(binding, for: aggregate)

    var next = aggregate
    next.phase = .running
    next.binding = binding
    next.stopIntent = nil
    next.failureReason = nil
    return next
  }

  fileprivate static func requestCodexApproval(
    _ aggregate: TaskAggregate,
    approvalID: ApprovalID,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.running, .awaitingCodexApproval], event: event)
    guard !aggregate.pendingApprovalIDs.contains(approvalID),
      !aggregate.resolvingApprovalIDs.contains(approvalID)
    else {
      throw TaskTransitionError.approvalAlreadyPending(approvalID)
    }

    var next = aggregate
    next.pendingApprovalIDs.insert(approvalID)
    next.phase = .awaitingCodexApproval
    return next
  }

  fileprivate static func recordCodexApprovalEvidence(
    _ aggregate: TaskAggregate,
    evidence: CodexApprovalEvidence,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.running, .awaitingCodexApproval], event: event)
    guard aggregate.binding?.threadID == evidence.threadID,
      aggregate.binding?.turnID == evidence.turnID,
      aggregate.approvalEvidenceByID[evidence.approvalID] == nil,
      !aggregate.pendingApprovalIDs.contains(evidence.approvalID),
      !aggregate.resolvingApprovalIDs.contains(evidence.approvalID)
    else { throw invalidTransition(aggregate, event: event) }

    var next = aggregate
    next.approvalEvidenceByID[evidence.approvalID] = evidence
    guard TaskAggregate.approvalEvidenceFitsBudget(next.approvalEvidenceByID) else {
      throw invalidTransition(aggregate, event: event)
    }
    return next
  }

  fileprivate static func approveCodexApproval(
    _ aggregate: TaskAggregate,
    approvalID: ApprovalID,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.awaitingCodexApproval], event: event)
    guard
      aggregate.pendingApprovalIDs.contains(approvalID)
        || aggregate.resolvingApprovalIDs.contains(approvalID)
    else {
      throw TaskTransitionError.approvalNotPending(approvalID)
    }

    var next = aggregate
    next.pendingApprovalIDs.remove(approvalID)
    next.resolvingApprovalIDs.remove(approvalID)
    next.approvalEvidenceByID[approvalID] = nil
    next.phase =
      next.pendingApprovalIDs.isEmpty && next.resolvingApprovalIDs.isEmpty
      ? .running : .awaitingCodexApproval
    return next
  }

  fileprivate static func reserveCodexApproval(
    _ aggregate: TaskAggregate,
    approvalID: ApprovalID,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.awaitingCodexApproval], event: event)
    guard aggregate.pendingApprovalIDs.contains(approvalID),
      !aggregate.resolvingApprovalIDs.contains(approvalID)
    else {
      throw TaskTransitionError.approvalNotPending(approvalID)
    }

    var next = aggregate
    next.pendingApprovalIDs.remove(approvalID)
    next.resolvingApprovalIDs.insert(approvalID)
    return next
  }

  fileprivate static func denyCodexApproval(
    _ aggregate: TaskAggregate,
    approvalID: ApprovalID,
    intent: StopIntent,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.awaitingCodexApproval], event: event)
    guard
      aggregate.pendingApprovalIDs.contains(approvalID)
        || aggregate.resolvingApprovalIDs.contains(approvalID)
    else {
      throw TaskTransitionError.approvalNotPending(approvalID)
    }
    guard aggregate.stopIntent == nil else {
      throw TaskTransitionError.stopAlreadyRequested
    }

    var next = aggregate
    next.pendingApprovalIDs.remove(approvalID)
    next.resolvingApprovalIDs.remove(approvalID)
    next.approvalEvidenceByID[approvalID] = nil
    next.stopIntent = intent
    return next
  }

  fileprivate static func setActivity(
    _ aggregate: TaskAggregate,
    activity: TaskActivity,
    event: TaskEvent
  ) throws -> TaskAggregate {
    let allowedPhases: Set<TaskPhase> =
      activity == .correcting
      ? [.running]
      : [.running, .awaitingCodexApproval, .verifying]
    try requirePhase(aggregate, allowedPhases, event: event)
    try requireActivityTransition(aggregate, to: activity, event: event)

    var next = aggregate
    next.activity = activity
    return next
  }

  fileprivate static func finishActivity(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(
      aggregate,
      [.running, .awaitingCodexApproval, .verifying],
      event: event
    )
    guard aggregate.activity != .idle else {
      throw invalidTransition(aggregate, event: event)
    }

    var next = aggregate
    next.activity = .idle
    return next
  }

  fileprivate static func requestStop(
    _ aggregate: TaskAggregate,
    intent: StopIntent,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.running, .awaitingCodexApproval], event: event)
    guard aggregate.stopIntent == nil else {
      throw TaskTransitionError.stopAlreadyRequested
    }

    var next = aggregate
    next.stopIntent = intent
    return next
  }

  fileprivate static func stopTurn(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.running, .awaitingCodexApproval], event: event)
    guard let intent = aggregate.stopIntent else {
      throw TaskTransitionError.stopIntentRequired
    }

    var next = aggregate
    next.phase = intent.outcome == .suspend ? .suspended : .interrupted
    next.activity = .idle
    next.pendingApprovalIDs.removeAll()
    next.resolvingApprovalIDs.removeAll()
    next.approvalEvidenceByID.removeAll()
    next.stopIntent = nil
    return next
  }

  fileprivate static func completeTurn(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.running, .awaitingCodexApproval], event: event)
    guard aggregate.pendingApprovalIDs.isEmpty, aggregate.resolvingApprovalIDs.isEmpty,
      aggregate.approvalEvidenceByID.isEmpty
    else {
      throw invalidTransition(aggregate, event: event)
    }

    var next = aggregate
    next.phase = .verifying
    next.activity = .idle
    next.stopIntent = nil
    return next
  }

  fileprivate static func requestRepair(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.verifying], event: event)

    var next = aggregate
    next.phase = .preparing
    next.activity = .idle
    next.reportReference = nil
    next.failureReason = nil
    return next
  }

  fileprivate static func storeReport(
    _ aggregate: TaskAggregate,
    reference: String,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.verifying], event: event)
    guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TaskTransitionError.invalidReportReference
    }

    var next = aggregate
    next.reportReference = reference
    return next
  }

  fileprivate static func recordCompletion(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.verifying], event: event)
    guard aggregate.reportReference != nil else {
      throw TaskTransitionError.reportRequired
    }

    var next = aggregate
    next.phase = .completed
    next.activity = .idle
    return next
  }

  fileprivate static func recordFailure(
    _ aggregate: TaskAggregate,
    reason: String,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(
      aggregate,
      [.preparing, .running, .awaitingCodexApproval, .verifying, .recovering, .unknown],
      event: event
    )

    var next = aggregate
    next.phase = .failed
    next.activity = .idle
    next.pendingApprovalIDs.removeAll()
    next.resolvingApprovalIDs.removeAll()
    next.approvalEvidenceByID.removeAll()
    next.stopIntent = nil
    next.failureReason = reason
    next.recoveryOrigin = nil
    return next
  }

  fileprivate static func resume(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.suspended], event: event)

    var next = aggregate
    next.phase = .preparing
    next.stopIntent = nil
    next.failureReason = nil
    return next
  }

  fileprivate static func startRecovery(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(
      aggregate,
      [.preparing, .running, .awaitingCodexApproval, .verifying, .unknown],
      event: event
    )

    var next = aggregate
    if aggregate.phase != .unknown {
      next.recoveryOrigin = aggregate.phase
    }
    next.phase = .recovering
    next.activity = .idle
    return next
  }

  fileprivate static func markRecoveryAmbiguous(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.recovering], event: event)

    var next = aggregate
    next.phase = .unknown
    return next
  }

  fileprivate static func resolveRecovery(
    _ aggregate: TaskAggregate,
    target: TaskPhase,
    event: TaskEvent
  ) throws -> TaskAggregate {
    try requirePhase(aggregate, [.recovering], event: event)
    let allowedTargets: Set<TaskPhase> = [
      .running,
      .awaitingCodexApproval,
      .suspended,
      .verifying,
      .completed,
      .interrupted,
    ]
    guard allowedTargets.contains(target) else {
      throw TaskTransitionError.invalidRecoveryTarget(target)
    }
    try validateRecoveryTarget(target, for: aggregate)

    var next = aggregate
    next.phase = target
    next.activity = .idle
    next.recoveryOrigin = nil
    if target != .awaitingCodexApproval {
      next.pendingApprovalIDs.removeAll()
      next.resolvingApprovalIDs.removeAll()
      next.approvalEvidenceByID.removeAll()
    }
    if target == .suspended || target == .verifying || target.isTerminal {
      next.stopIntent = nil
    }
    return next
  }
}

extension TaskReducer {
  fileprivate static func requirePhase(
    _ aggregate: TaskAggregate,
    _ allowed: Set<TaskPhase>,
    event: TaskEvent
  ) throws {
    guard allowed.contains(aggregate.phase) else {
      throw invalidTransition(aggregate, event: event)
    }
  }

  fileprivate static func invalidTransition(
    _ aggregate: TaskAggregate,
    event: TaskEvent
  ) -> TaskTransitionError {
    .invalidTransition(phase: aggregate.phase, event: event.kind)
  }

  fileprivate static func requireActivityTransition(
    _ aggregate: TaskAggregate,
    to activity: TaskActivity,
    event: TaskEvent
  ) throws {
    let allowed =
      switch activity {
      case .supervising:
        aggregate.activity == .idle
      case .correcting:
        aggregate.activity == .supervising
      case .idle:
        false
      }
    guard allowed else {
      throw invalidTransition(aggregate, event: event)
    }
  }

  fileprivate static func validate(_ submission: TaskSubmission) throws {
    let requiredValues = [
      ("idempotencyKey", submission.idempotencyKey.rawValue),
      ("projectID", submission.projectID.rawValue),
      ("execution.model", submission.execution.model),
      ("execution.effort", submission.execution.effort),
      ("execution.permissionMode", submission.execution.permissionMode),
      ("contract.goal", submission.contract.goal),
    ]

    if let invalid = requiredValues.first(where: { isBlank($0.1) }) {
      throw TaskTransitionError.invalidSubmission(field: invalid.0)
    }
    guard submission.contract.acceptanceCriteria.contains(where: { !isBlank($0) }) else {
      throw TaskTransitionError.invalidSubmission(field: "contract.acceptanceCriteria")
    }
    try validateSupervisor(submission.supervisor)
    try validateThreadTarget(submission.thread)
  }

  fileprivate static func validateSupervisor(_ supervisor: SupervisorOptions) throws {
    guard supervisor.enabled else { return }
    guard !isBlank(supervisor.model) else {
      throw TaskTransitionError.invalidSubmission(field: "supervisor.model")
    }
    guard !isBlank(supervisor.effort) else {
      throw TaskTransitionError.invalidSubmission(field: "supervisor.effort")
    }
  }

  fileprivate static func validateThreadTarget(_ target: ThreadTarget) throws {
    guard case .existing(let threadID) = target else { return }
    guard !isBlank(threadID.rawValue) else {
      throw TaskTransitionError.invalidSubmission(field: "thread.threadID")
    }
  }

  fileprivate static func validate(
    _ binding: ExecutionBinding,
    for aggregate: TaskAggregate
  ) throws {
    guard !isBlank(binding.threadID.rawValue), !isBlank(binding.turnID.rawValue) else {
      throw TaskTransitionError.invalidBinding(reason: "empty identifier")
    }

    if let current = aggregate.binding {
      try validateNextBinding(binding, after: current)
      return
    }

    guard binding.turnGeneration == 1 else {
      throw TaskTransitionError.invalidBinding(reason: "initial generation must be 1")
    }
    guard case .existing(let expectedThreadID) = aggregate.submission.thread else { return }
    guard binding.threadID == expectedThreadID else {
      throw TaskTransitionError.invalidBinding(reason: "thread does not match submission")
    }
  }

  fileprivate static func validateNextBinding(
    _ binding: ExecutionBinding,
    after current: ExecutionBinding
  ) throws {
    guard binding.threadID == current.threadID else {
      throw TaskTransitionError.invalidBinding(reason: "thread changed between turns")
    }
    guard binding.turnID != current.turnID else {
      throw TaskTransitionError.invalidBinding(reason: "turn identifier was reused")
    }
    guard binding.turnGeneration == current.turnGeneration + 1 else {
      throw TaskTransitionError.invalidBinding(reason: "turn generation is not consecutive")
    }
  }

  fileprivate static func validateRecoveryTarget(
    _ target: TaskPhase,
    for aggregate: TaskAggregate
  ) throws {
    if target == .completed, aggregate.reportReference == nil {
      throw TaskTransitionError.reportRequired
    }
    if target == .running,
      !aggregate.pendingApprovalIDs.isEmpty || !aggregate.resolvingApprovalIDs.isEmpty
        || !aggregate.approvalEvidenceByID.isEmpty
    {
      throw TaskTransitionError.invalidRecoveryTarget(target)
    }
    if target == .awaitingCodexApproval,
      aggregate.pendingApprovalIDs.isEmpty || !aggregate.resolvingApprovalIDs.isEmpty
        || !Set(aggregate.approvalEvidenceByID.keys).isSubset(
          of: aggregate.pendingApprovalIDs
        )
    {
      throw TaskTransitionError.invalidRecoveryTarget(target)
    }
    if target == .running || target == .awaitingCodexApproval {
      guard aggregate.binding != nil else {
        throw TaskTransitionError.invalidBinding(reason: "active task has no execution binding")
      }
    }
  }

  fileprivate static func isBlank(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
