import BridgeDomain
import BridgePersistence
import CryptoKit
import Foundation

public actor TaskCoordinator {
  private enum StoredRecord: Codable {
    case submission(TaskSubmission)
    case domain(TaskEvent)
    case runtimeIntent(TaskRuntimeIntentRecord)
    case semantic(TaskSemanticExecutionObservation)
    case finalization(TaskFinalizationRecord)
  }

  private struct TaskRuntimeIntentRecord: Codable {
    let kind: String
    let identifier: String
    let approved: Bool?
    let detail: String?
  }

  private struct TaskFinalizationRecord: Codable {
    let kind: String
    let detail: String
    let pipelineReservation: TaskPipelineFinalizationReservation?
  }

  private struct PreparedExecutionRecord: Codable {
    let threadID: String
    let turnGeneration: UInt64
    let lockKeys: [String]
  }

  private struct StoredProjection: Codable {
    let aggregate: TaskAggregate
    let lastSequence: Int64
  }

  let store: EventStore
  private let admission: any TaskAdmissionPolicy
  let runtime: any TaskExecutionRuntime
  let pipeline: (any TaskPipelineLifecycle)?
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()
  private var workers: [TaskID: Task<Void, Never>] = [:]
  private var pendingStarts: Set<TaskID> = []

  public init(
    store: EventStore,
    admission: any TaskAdmissionPolicy,
    runtime: any TaskExecutionRuntime,
    pipeline: (any TaskPipelineLifecycle)? = nil
  ) {
    self.store = store
    self.admission = admission
    self.runtime = runtime
    self.pipeline = pipeline
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
  }

  public func submit(origin: String, submission: TaskSubmission) async throws -> TaskProjection {
    try await submitWithResult(origin: origin, submission: submission).projection
  }

  public func submitWithResult(
    origin: String,
    submission: TaskSubmission
  ) async throws -> TaskSubmissionResult {
    let identity = try submissionIdentity(origin: origin, submission: submission)
    let normalizedOrigin = identity.origin
    let fingerprint = identity.fingerprint
    if let claimedTaskID = try await store.submissionClaim(
      origin: normalizedOrigin,
      key: submission.idempotencyKey,
      requestFingerprint: fingerprint
    ), let existing = try await projectionIfPresent(claimedTaskID) {
      return TaskSubmissionResult(projection: existing, reusedExistingTask: true)
    }
    let admissionDecision = try await admission.decision(for: submission)
    try Self.validateSubmission(submission, decision: admissionDecision)
    let candidate = TaskID(rawValue: "tsk_\(Self.randomIdentifier())")
    let firstEvent: TaskEvent =
      admissionDecision == .requireLocalApproval
      ? .localApprovalRequested
      : .preparationStarted
    let initialRecords: [StoredRecord] = [.submission(submission), .domain(firstEvent)]
    let createdAt = Date()
    let initialEvents = try initialRecords.enumerated().map { index, record in
      try envelope(
        record,
        taskID: candidate,
        sequence: Int64(index + 1),
        createdAt: createdAt
      )
    }
    let initialAggregate = try TaskReducer.reduce(
      TaskAggregate(id: candidate, submission: submission),
      event: firstEvent
    )
    let initialProjection = TaskProjection(
      aggregate: initialAggregate,
      lastSequence: Int64(initialEvents.count)
    )
    let taskID = try await store.claimSubmission(
      origin: normalizedOrigin,
      key: submission.idempotencyKey,
      requestFingerprint: fingerprint,
      taskID: candidate,
      initialEvents: initialEvents,
      initialSnapshot: try stateSnapshot(for: initialProjection),
      createdAt: createdAt
    )
    guard let projection = try await projectionIfPresent(taskID) else {
      throw TaskCoordinatorError.corruptTask(taskID)
    }
    if projection.aggregate.phase == .preparing { requestStart(taskID) }
    return TaskSubmissionResult(
      projection: projection,
      reusedExistingTask: taskID != candidate
    )
  }

  public func existingSubmissionResult(
    origin: String,
    submission: TaskSubmission
  ) async throws -> TaskSubmissionResult? {
    let identity = try submissionIdentity(origin: origin, submission: submission)
    guard
      let taskID = try await store.submissionClaim(
        origin: identity.origin,
        key: submission.idempotencyKey,
        requestFingerprint: identity.fingerprint
      )
    else { return nil }
    guard let projection = try await projectionIfPresent(taskID) else {
      throw TaskCoordinatorError.corruptTask(taskID)
    }
    return TaskSubmissionResult(projection: projection, reusedExistingTask: true)
  }

  public func task(_ taskID: TaskID) async throws -> TaskProjection {
    guard let projection = try await projectionIfPresent(taskID) else {
      throw TaskCoordinatorError.unknownTask(taskID)
    }
    return projection
  }

  public func resolveLocalApproval(taskID: TaskID, approved: Bool) async throws -> TaskProjection {
    let projection = try await appendDomain(
      .localApprovalResolved(approved: approved),
      taskID: taskID
    )
    if projection.aggregate.phase == .preparing { requestStart(taskID) }
    return projection
  }

  public func resolveCodexApproval(
    taskID: TaskID,
    approvalID: ApprovalID,
    approved: Bool
  ) async throws -> TaskProjection {
    guard !approved else { throw TaskCoordinatorError.codexApprovalAuthorizationUnavailable }
    guard Self.isValidIdentifier(approvalID.rawValue) else {
      throw TaskCoordinatorError.invalidApprovalIdentifier
    }
    let reserved = try await reserveApprovalResolution(
      taskID: taskID,
      approvalID: approvalID,
      approved: approved
    )
    var responseSent = false
    var resolutionCommitted = false
    do {
      try await runtime.resolveApproval(
        taskID: taskID,
        approvalID: approvalID,
        approved: approved
      )
      responseSent = true
      if approved {
        let projection = try await appendDomain(
          .codexApprovalApproved(approvalID),
          taskID: taskID
        )
        await runtime.finalizeApprovalResolution(
          taskID: taskID,
          approvalID: approvalID,
          committed: true
        )
        resolutionCommitted = true
        return projection
      }
      let stopIntent = StopIntent(
        operationID: OperationID(rawValue: "op_\(Self.randomIdentifier())"),
        outcome: .interrupt,
        reason: "Local user denied the Codex approval."
      )
      let projection = try await appendDomain(
        .codexApprovalDenied(approvalID, stopIntent),
        taskID: taskID
      )
      await runtime.finalizeApprovalResolution(
        taskID: taskID,
        approvalID: approvalID,
        committed: true
      )
      resolutionCommitted = true
      if let binding = projection.aggregate.binding {
        try await runtime.interrupt(taskID: taskID, binding: binding)
      }
      return projection
    } catch {
      if responseSent, !resolutionCommitted {
        await runtime.finalizeApprovalResolution(
          taskID: taskID,
          approvalID: approvalID,
          committed: false
        )
      }
      await abortAndRecordRuntimeFailure(
        error,
        taskID: taskID,
        expectedBinding: reserved.aggregate.binding
      )
      throw error
    }
  }

  private func reserveApprovalResolution(
    taskID: TaskID,
    approvalID: ApprovalID,
    approved: Bool
  ) async throws -> TaskProjection {
    while true {
      let current = try await task(taskID)
      guard current.aggregate.pendingApprovalIDs.contains(approvalID) else {
        throw TaskTransitionError.approvalNotPending(approvalID)
      }
      let domainEvent = TaskEvent.codexApprovalResolutionRequested(
        approvalID,
        approved: approved
      )
      let aggregate = try TaskReducer.reduce(current.aggregate, event: domainEvent)
      let intent = TaskRuntimeIntentRecord(
        kind: "resolve_codex_approval",
        identifier: approvalID.rawValue,
        approved: approved,
        detail: nil
      )
      let intentSequence = try Self.nextSequence(
        after: current.lastSequence,
        taskID: taskID
      )
      let domainSequence = try Self.nextSequence(after: intentSequence, taskID: taskID)
      let projection = TaskProjection(aggregate: aggregate, lastSequence: domainSequence)
      let createdAt = Date()
      do {
        try await store.appendBatch(
          [
            try envelope(
              .runtimeIntent(intent),
              taskID: taskID,
              sequence: intentSequence,
              createdAt: createdAt
            ),
            try envelope(
              .domain(domainEvent),
              taskID: taskID,
              sequence: domainSequence,
              createdAt: createdAt
            ),
          ],
          expectedLastSequence: current.lastSequence,
          snapshot: try stateSnapshot(for: projection)
        )
        return projection
      } catch EventStoreError.optimisticConcurrencyConflict(let conflictedTaskID, _, _) {
        guard conflictedTaskID == taskID else {
          throw TaskCoordinatorError.corruptTask(taskID)
        }
      }
    }
  }

  public func interrupt(taskID: TaskID, reason: String? = nil) async throws -> TaskProjection {
    try await interruptWithResult(taskID: taskID, reason: reason).projection
  }

  public func interruptWithResult(
    taskID: TaskID,
    reason: String? = nil
  ) async throws -> TaskMutationResult {
    try await requestStop(
      taskID: taskID,
      expectedTurnID: nil,
      outcome: .interrupt,
      reason: reason
    )
  }

  public func interruptWithResult(
    taskID: TaskID,
    expectedTurnID: TurnID,
    reason: String? = nil
  ) async throws -> TaskMutationResult {
    try await requestStop(
      taskID: taskID,
      expectedTurnID: expectedTurnID,
      outcome: .interrupt,
      reason: reason
    )
  }

  public func steer(taskID: TaskID, prompt: String) async throws -> TaskProjection {
    try await steerWithResult(taskID: taskID, prompt: prompt).projection
  }

  public func steerWithResult(
    taskID: TaskID,
    prompt: String
  ) async throws -> TaskMutationResult {
    try await steerWithResult(taskID: taskID, expectedTurnID: nil, prompt: prompt)
  }

  public func steerWithResult(
    taskID: TaskID,
    expectedTurnID: TurnID,
    prompt: String
  ) async throws -> TaskMutationResult {
    try await steerWithResult(
      taskID: taskID,
      expectedTurnID: Optional(expectedTurnID),
      prompt: prompt
    )
  }

  private func steerWithResult(
    taskID: TaskID,
    expectedTurnID: TurnID?,
    prompt: String
  ) async throws -> TaskMutationResult {
    let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized == prompt, normalized.utf8.count <= 16 * 1024,
      !normalized.contains("\0")
    else {
      throw TaskCoordinatorError.invalidSteerPrompt
    }
    let current = try await task(taskID)
    guard current.aggregate.phase == .running, let binding = current.aggregate.binding else {
      throw TaskCoordinatorError.executionUnavailable(taskID)
    }
    guard expectedTurnID.map({ $0 == binding.turnID }) ?? true else {
      throw TaskCoordinatorTurnMismatchError()
    }
    let operationID = OperationID(rawValue: "op_\(Self.randomIdentifier())")
    let intent = TaskRuntimeIntentRecord(
      kind: "steer",
      identifier: operationID.rawValue,
      approved: nil,
      detail: normalized
    )
    try await append(
      .runtimeIntent(intent),
      taskID: taskID,
      expectedSequence: current.lastSequence,
      projection: try advancedProjection(current)
    )
    do {
      try await runtime.steer(taskID: taskID, binding: binding, prompt: normalized)
      return TaskMutationResult(
        projection: try await task(taskID),
        operationID: operationID
      )
    } catch {
      await abortAndRecordRuntimeFailure(error, taskID: taskID, expectedBinding: binding)
      throw error
    }
  }

  public func suspend(taskID: TaskID, reason: String? = nil) async throws -> TaskProjection {
    try await requestStop(
      taskID: taskID,
      expectedTurnID: nil,
      outcome: .suspend,
      reason: reason
    ).projection
  }

  public func resume(taskID: TaskID) async throws -> TaskProjection {
    let projection = try await appendDomain(.resumeRequested, taskID: taskID)
    requestStart(taskID)
    return projection
  }

  private func requestStop(
    taskID: TaskID,
    expectedTurnID: TurnID?,
    outcome: StopIntent.Outcome,
    reason: String?
  ) async throws -> TaskMutationResult {
    let current = try await task(taskID)
    guard let binding = current.aggregate.binding else {
      throw TaskCoordinatorError.executionUnavailable(taskID)
    }
    guard expectedTurnID.map({ $0 == binding.turnID }) ?? true else {
      throw TaskCoordinatorTurnMismatchError()
    }
    let intent = StopIntent(
      operationID: OperationID(rawValue: "op_\(Self.randomIdentifier())"),
      outcome: outcome,
      reason: reason
    )
    let aggregate = try TaskReducer.reduce(current.aggregate, event: .stopRequested(intent))
    let projection = TaskProjection(
      aggregate: aggregate,
      lastSequence: try Self.nextSequence(after: current.lastSequence, taskID: taskID)
    )
    try await append(
      .domain(.stopRequested(intent)),
      taskID: taskID,
      expectedSequence: current.lastSequence,
      projection: projection
    )
    do {
      try await runtime.interrupt(taskID: taskID, binding: binding)
      return TaskMutationResult(projection: projection, operationID: intent.operationID)
    } catch {
      await abortAndRecordRuntimeFailure(error, taskID: taskID, expectedBinding: binding)
      throw error
    }
  }

  /// Low-level compatibility boundary for callers that already validated authoritative evidence.
  /// Production composition must not construct this authorization from untrusted model output.
  public func complete(
    taskID: TaskID,
    reportReference: String,
    authorization: TaskFinalizationAuthorization
  ) async throws -> TaskProjection {
    let reference = reportReference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reference.isEmpty, reference.utf8.count <= 1_024 else {
      throw TaskCoordinatorError.invalidReportReference
    }
    let record = try Self.finalizationRecord(authorization)
    let current = try await task(taskID)
    if current.lastSequence > 0,
      try await storedPipelineReservation(after: current.lastSequence - 1, taskID: taskID) != nil
    {
      throw TaskCoordinatorError.finalizationReservationMismatch
    }
    _ = try TaskReducer.reduce(
      current.aggregate,
      event: .finalReportStored(reference: reference)
    )
    try await append(
      .finalization(record),
      taskID: taskID,
      expectedSequence: current.lastSequence,
      projection: try advancedProjection(current)
    )
    _ = try await appendDomain(.finalReportStored(reference: reference), taskID: taskID)
    let completed = try await appendDomain(
      .completionRecorded,
      taskID: taskID,
      releasesOwnedLocks: true
    )
    pendingStarts.remove(taskID)
    workers[taskID]?.cancel()
    return completed
  }

  public func preparePipelineFinalization(
    taskID: TaskID,
    expectedBinding: ExecutionBinding,
    expectedSequence: Int64,
    reportReference: String,
    reportDigest: String,
    supervisorDecisionDigest: String
  ) async throws -> TaskPipelineFinalizationReservation {
    let reference = reportReference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard reference == reportReference, !reference.isEmpty, reference.utf8.count <= 1_024,
      Self.isLowercaseSHA256(reportDigest), reference == "report:sha256:\(reportDigest)",
      Self.isLowercaseSHA256(supervisorDecisionDigest), expectedSequence > 0
    else { throw TaskCoordinatorError.finalizationReservationMismatch }
    let reservationSequence = try Self.nextSequence(after: expectedSequence, taskID: taskID)
    let reservation = TaskPipelineFinalizationReservation(
      taskID: taskID,
      binding: expectedBinding,
      originalSequence: expectedSequence,
      reservationSequence: reservationSequence,
      reportReference: reference,
      reportDigest: reportDigest,
      supervisorDecisionDigest: supervisorDecisionDigest
    )
    let current = try await task(taskID)
    guard current.aggregate.phase == .verifying,
      current.aggregate.binding == expectedBinding
    else { throw TaskCoordinatorError.finalizationReservationMismatch }
    if current.lastSequence == reservationSequence {
      guard
        try await storedPipelineReservation(after: expectedSequence, taskID: taskID) == reservation
      else { throw TaskCoordinatorError.finalizationReservationMismatch }
      return reservation
    }
    guard current.lastSequence == expectedSequence else {
      throw TaskCoordinatorError.finalizationReservationMismatch
    }
    let record = TaskFinalizationRecord(
      kind: "pipeline_finalization_prepared",
      detail: supervisorDecisionDigest,
      pipelineReservation: reservation
    )
    try await append(
      .finalization(record),
      taskID: taskID,
      expectedSequence: expectedSequence,
      projection: try advancedProjection(current)
    )
    return reservation
  }

  public func commitPipelineFinalization(
    _ reservation: TaskPipelineFinalizationReservation
  ) async throws -> TaskProjection {
    guard
      try await storedPipelineReservation(
        after: reservation.originalSequence,
        taskID: reservation.taskID
      ) == reservation
    else { throw TaskCoordinatorError.finalizationReservationMismatch }
    let current = try await task(reservation.taskID)
    guard current.aggregate.phase == .verifying,
      current.aggregate.binding == reservation.binding,
      current.lastSequence == reservation.reservationSequence
    else { throw TaskCoordinatorError.finalizationReservationMismatch }

    let reportEvent = TaskEvent.finalReportStored(reference: reservation.reportReference)
    let reportAggregate = try TaskReducer.reduce(current.aggregate, event: reportEvent)
    let completedAggregate = try TaskReducer.reduce(reportAggregate, event: .completionRecorded)
    let reportSequence = try Self.nextSequence(
      after: reservation.reservationSequence,
      taskID: reservation.taskID
    )
    let completionSequence = try Self.nextSequence(
      after: reportSequence,
      taskID: reservation.taskID
    )
    let date = Date()
    let events = try [
      envelope(
        .domain(reportEvent),
        taskID: reservation.taskID,
        sequence: reportSequence,
        createdAt: date
      ),
      envelope(
        .domain(.completionRecorded),
        taskID: reservation.taskID,
        sequence: completionSequence,
        createdAt: date
      ),
    ]
    let completed = TaskProjection(
      aggregate: completedAggregate,
      lastSequence: completionSequence
    )
    try await store.appendBatchReleasingOwnedLocks(
      events,
      expectedLastSequence: reservation.reservationSequence,
      snapshot: try stateSnapshot(for: completed)
    )
    pendingStarts.remove(reservation.taskID)
    workers[reservation.taskID]?.cancel()
    return completed
  }

  public func recoverIncompleteTasks() async throws -> [TaskProjection] {
    var recovered: [TaskProjection] = []
    var cursor: TaskID?
    while true {
      try Task.checkCancellation()
      let taskIDs = try await store.taskIDsRequiringRecovery(afterTaskID: cursor, limit: 200)
      guard !taskIDs.isEmpty else { break }
      for taskID in taskIDs {
        try Task.checkCancellation()
        var current = try await task(taskID)
        if current.aggregate.phase.isTerminal || current.aggregate.phase == .suspended {
          try await releaseOwnedLocks(taskID)
          try await pipeline?.discardTaskState(taskID: taskID)
          continue
        }
        if !current.aggregate.resolvingApprovalIDs.isEmpty {
          current = try await appendDomain(
            .failureRecorded(reason: "Approval resolution was ambiguous after restart."),
            taskID: taskID,
            releasesOwnedLocks: true
          )
          try await pipeline?.discardTaskState(taskID: taskID)
          recovered.append(current)
          continue
        }
        if current.aggregate.phase == .verifying,
          current.lastSequence > 0,
          try await storedPipelineReservation(after: current.lastSequence - 1, taskID: taskID)
            != nil
        {
          continue
        }
        guard Self.requiresRecovery(current.aggregate.phase) || current.aggregate.phase == .unknown
        else { continue }
        if let reconciled = try await reconcileRecovery(current) {
          recovered.append(reconciled)
        }
      }
      cursor = taskIDs.last
    }
    return recovered
  }

  public func resolveRecovery(taskID: TaskID, to phase: TaskPhase) async throws -> TaskProjection {
    let current = try await task(taskID)
    guard current.aggregate.phase == .recovering else {
      throw TaskCoordinatorError.recoveryRequiresReconciliation(current.aggregate.phase)
    }
    guard phase == .suspended else {
      throw TaskCoordinatorError.recoveryRequiresReconciliation(phase)
    }
    let projection = try await appendDomain(
      .recoveryResolved(to: phase),
      taskID: taskID,
      releasesOwnedLocks: true
    )
    try await pipeline?.discardTaskState(taskID: taskID)
    return projection
  }

  public func suspendAmbiguousRecovery(taskID: TaskID) async throws -> TaskProjection {
    let current = try await task(taskID)
    if current.aggregate.phase == .suspended {
      try await releaseOwnedLocks(taskID)
      try await pipeline?.discardTaskState(taskID: taskID)
      return current
    }
    guard current.aggregate.phase == .unknown else {
      throw TaskCoordinatorError.recoveryRequiresReconciliation(current.aggregate.phase)
    }
    do {
      let projection = try await commitRecoveryEvents(
        [.recoveryStarted, .recoveryResolved(to: .suspended)],
        current: current,
        releasesOwnedLocks: true
      )
      try await pipeline?.discardTaskState(taskID: taskID)
      return projection
    } catch {
      if let latest = try? await task(taskID), latest.aggregate.phase == .suspended {
        try await releaseOwnedLocks(taskID)
        try await pipeline?.discardTaskState(taskID: taskID)
        return latest
      }
      throw error
    }
  }

  public func failPipelineRecovery(
    taskID: TaskID,
    expectedBinding: ExecutionBinding,
    expectedSequence: Int64
  ) async throws -> TaskProjection {
    let current = try await task(taskID)
    guard current.aggregate.phase == .verifying,
      current.aggregate.binding == expectedBinding,
      current.lastSequence == expectedSequence
    else {
      throw TaskCoordinatorError.recoveryRequiresReconciliation(current.aggregate.phase)
    }
    let event = TaskEvent.failureRecorded(reason: "Task pipeline recovery failed.")
    let aggregate = try TaskReducer.reduce(current.aggregate, event: event)
    let projection = TaskProjection(
      aggregate: aggregate,
      lastSequence: try Self.nextSequence(after: current.lastSequence, taskID: taskID)
    )
    try await append(
      .domain(event),
      taskID: taskID,
      expectedSequence: current.lastSequence,
      releasesOwnedLocks: true,
      projection: projection
    )
    try await pipeline?.discardTaskState(taskID: taskID)
    return projection
  }

  public func beginRecoveryReconciliation(taskID: TaskID) async throws -> TaskProjection {
    let current = try await task(taskID)
    guard current.aggregate.phase == .unknown else {
      throw TaskCoordinatorError.recoveryRequiresReconciliation(current.aggregate.phase)
    }
    return try await appendDomain(.recoveryStarted, taskID: taskID)
  }

  func commitRecoveryEvents(
    _ events: [TaskEvent],
    current: TaskProjection,
    releasesOwnedLocks: Bool = false
  ) async throws -> TaskProjection {
    var aggregate = current.aggregate
    var sequence = current.lastSequence
    let createdAt = Date()
    var envelopes: [TaskEventEnvelope] = []
    for event in events {
      aggregate = try TaskReducer.reduce(aggregate, event: event)
      sequence = try Self.nextSequence(after: sequence, taskID: current.aggregate.id)
      envelopes.append(
        try envelope(
          .domain(event),
          taskID: current.aggregate.id,
          sequence: sequence,
          createdAt: createdAt
        )
      )
    }
    let projection = TaskProjection(aggregate: aggregate, lastSequence: sequence)
    let snapshot = try stateSnapshot(for: projection)
    if releasesOwnedLocks {
      try await store.appendBatchReleasingOwnedLocks(
        envelopes,
        expectedLastSequence: current.lastSequence,
        snapshot: snapshot
      )
    } else {
      try await store.appendBatch(
        envelopes,
        expectedLastSequence: current.lastSequence,
        snapshot: snapshot
      )
    }
    return projection
  }

  private func requestStart(_ taskID: TaskID) {
    guard workers[taskID] == nil else {
      pendingStarts.insert(taskID)
      return
    }
    scheduleStart(taskID)
  }

  private func scheduleStart(_ taskID: TaskID) {
    guard workers[taskID] == nil else { return }
    workers[taskID] = Task { [weak self] in
      await self?.startPreparedTask(taskID)
    }
  }

  private func startPreparedTask(_ taskID: TaskID) async {
    defer { finishWorker(taskID) }
    var failureBinding: ExecutionBinding?
    do {
      let current = try await task(taskID)
      guard current.aggregate.phase == .preparing else { return }
      failureBinding = current.aggregate.binding
      let lockKeys = try await runtime.lockKeys(
        for: current.aggregate.submission,
        previousBinding: current.aggregate.binding
      )
      try await ensureLocks(lockKeys, taskID: taskID)
      var startedBinding: ExecutionBinding?
      do {
        let session = try await startRuntime(
          taskID: taskID,
          current: current,
          provisionalLockKeys: lockKeys
        )
        startedBinding = session.binding
        _ = try await appendDomain(.turnStarted(session.binding), taskID: taskID)
        failureBinding = session.binding
        await consume(session.observations, taskID: taskID, binding: session.binding)
      } catch {
        if let startedBinding {
          await abortAndRecordRuntimeFailure(
            error,
            taskID: taskID,
            expectedBinding: startedBinding
          )
        } else {
          try? await recordRuntimeFailure(
            error,
            taskID: taskID,
            expectedBinding: failureBinding
          )
        }
      }
    } catch {
      try? await recordRuntimeFailure(
        error,
        taskID: taskID,
        expectedBinding: failureBinding
      )
    }
  }

  private func startRuntime(
    taskID: TaskID,
    current: TaskProjection,
    provisionalLockKeys: [String]
  ) async throws -> TaskExecutionSession {
    guard let durableRuntime = runtime as? any DurableTaskExecutionRuntime else {
      try await pipeline?.prepareForLegacyTurnStart(
        taskID: taskID,
        submission: current.aggregate.submission
      )
      return try await runtime.start(
        taskID: taskID,
        submission: current.aggregate.submission,
        previousBinding: current.aggregate.binding
      )
    }
    do {
      let preparation = try await durableRuntime.prepare(
        taskID: taskID,
        submission: current.aggregate.submission,
        previousBinding: current.aggregate.binding
      )
      try Self.validate(
        preparation,
        previousBinding: current.aggregate.binding,
        taskID: taskID
      )
      let preparedProjection = try await persist(
        preparation,
        taskID: taskID,
        current: current,
        replacing: provisionalLockKeys
      )
      let intent = TaskRuntimeIntentRecord(
        kind: "turn_start_requested",
        identifier: preparation.threadID.rawValue,
        approved: nil,
        detail: String(preparation.turnGeneration)
      )
      let startIntentProjection = try advancedProjection(preparedProjection)
      try await append(
        .runtimeIntent(intent),
        taskID: taskID,
        expectedSequence: preparedProjection.lastSequence,
        projection: startIntentProjection
      )
      let preStart = TaskPipelinePreStartContext(
        taskID: taskID,
        submission: current.aggregate.submission,
        preparation: preparation,
        startIntentSequence: startIntentProjection.lastSequence
      )
      try await pipeline?.prepareForTurnStart(preStart)
      let session = try await durableRuntime.startPrepared(
        taskID: taskID,
        submission: current.aggregate.submission,
        preparation: preparation
      )
      guard session.binding.threadID == preparation.threadID,
        session.binding.turnGeneration == preparation.turnGeneration
      else {
        throw TaskCoordinatorError.corruptTask(taskID)
      }
      try await pipeline?.recordStartedTurn(
        TaskPipelineStartedContext(preStart: preStart, binding: session.binding)
      )
      return session
    } catch {
      await durableRuntime.cancelPreparation(taskID: taskID)
      throw error
    }
  }

  private func persist(
    _ preparation: PreparedTaskExecution,
    taskID: TaskID,
    current: TaskProjection,
    replacing provisionalLockKeys: [String]
  ) async throws -> TaskProjection {
    let record = PreparedExecutionRecord(
      threadID: preparation.threadID.rawValue,
      turnGeneration: preparation.turnGeneration,
      lockKeys: preparation.lockKeys.sorted()
    )
    let detailData = try encoder.encode(record)
    guard let detail = String(data: detailData, encoding: .utf8) else {
      throw TaskCoordinatorError.corruptTask(taskID)
    }
    let intent = TaskRuntimeIntentRecord(
      kind: "execution_prepared",
      identifier: preparation.threadID.rawValue,
      approved: nil,
      detail: detail
    )
    let projection = try advancedProjection(current)
    let event = try envelope(
      .runtimeIntent(intent),
      taskID: taskID,
      sequence: projection.lastSequence,
      createdAt: Date()
    )
    try await store.appendRekeyingOwnedLocks(
      event,
      expectedLastSequence: current.lastSequence,
      from: provisionalLockKeys,
      to: preparation.lockKeys,
      snapshot: try stateSnapshot(for: projection)
    )
    return projection
  }

  private func finishWorker(_ taskID: TaskID) {
    workers[taskID] = nil
    guard pendingStarts.remove(taskID) != nil else { return }
    scheduleStart(taskID)
  }

  private func consume(
    _ observations: AsyncStream<TaskExecutionObservation>,
    taskID: TaskID,
    binding: ExecutionBinding
  ) async {
    for await observation in observations {
      let projection: TaskProjection
      do {
        guard
          let applied = try await applyWithRetry(
            observation,
            taskID: taskID,
            binding: binding
          )
        else {
          return
        }
        projection = applied
      } catch {
        await abortAndRecordRuntimeFailure(error, taskID: taskID, expectedBinding: binding)
        return
      }
      do {
        try await handlePipelineObservation(
          observation,
          projection: projection,
          taskID: taskID
        )
      } catch {
        await abortAndRecordRuntimeFailure(error, taskID: taskID, expectedBinding: binding)
        return
      }
      switch observation {
      case .turnCompleted, .turnStopped, .failed:
        return
      case .codexApprovalRequested, .semantic:
        break
      }
      guard let phase = try? await task(taskID).aggregate.phase else { return }
      if phase.isTerminal || phase == .suspended || phase == .verifying { return }
    }
    guard let projection = try? await task(taskID) else { return }
    let phase = projection.aggregate.phase
    guard !phase.isTerminal, phase != .suspended, phase != .verifying else { return }
    await abortAndRecordRuntimeFailure(
      TaskCoordinatorError.executionUnavailable(taskID),
      taskID: taskID,
      expectedBinding: binding
    )
  }

  private func abortAndRecordRuntimeFailure(
    _ error: any Error,
    taskID: TaskID,
    expectedBinding: ExecutionBinding?
  ) async {
    guard let expectedBinding else {
      try? await recordRuntimeFailure(error, taskID: taskID, expectedBinding: nil)
      return
    }
    do {
      try await runtime.abortSession(taskID: taskID, binding: expectedBinding)
    } catch {
      return
    }
    try? await recordRuntimeFailure(error, taskID: taskID, expectedBinding: expectedBinding)
  }

  private func handlePipelineObservation(
    _ observation: TaskExecutionObservation,
    projection: TaskProjection,
    taskID: TaskID
  ) async throws {
    switch observation {
    case .turnCompleted:
      guard projection.aggregate.phase == .verifying else {
        throw TaskCoordinatorError.corruptTask(taskID)
      }
      try await pipeline?.finalizeVerifyingTask(
        TaskPipelineVerifyingContext(projection: projection)
      )
    case .turnStopped, .failed:
      try await pipeline?.discardTaskState(taskID: taskID)
    case .codexApprovalRequested:
      break
    case .semantic(let semantic):
      guard let binding = projection.aggregate.binding else {
        throw TaskCoordinatorError.corruptTask(taskID)
      }
      try await pipeline?.recordSemanticObservation(
        TaskPipelineSemanticContext(
          projection: projection,
          binding: binding,
          observation: semantic
        )
      )
    }
  }

  private func apply(
    _ observation: TaskExecutionObservation,
    taskID: TaskID,
    binding: ExecutionBinding
  ) async throws -> TaskProjection? {
    let current = try await task(taskID)
    guard current.aggregate.binding == binding else { return nil }
    let event: TaskEvent
    let releasesLocks: Bool
    switch observation {
    case .codexApprovalRequested(let approvalID):
      guard Self.isValidIdentifier(approvalID.rawValue) else {
        throw TaskCoordinatorError.invalidApprovalIdentifier
      }
      return try await applyApprovalRequest(
        approvalID,
        current: current,
        taskID: taskID,
        binding: binding
      )
    case .semantic(let semantic):
      let projection = TaskProjection(
        aggregate: current.aggregate,
        lastSequence: try Self.nextSequence(after: current.lastSequence, taskID: taskID)
      )
      try await append(
        .semantic(semantic),
        taskID: taskID,
        expectedSequence: current.lastSequence,
        projection: projection
      )
      return projection
    case .turnCompleted:
      event = .turnCompleted
      releasesLocks = false
    case .turnStopped:
      event = .turnStopped
      releasesLocks = true
    case .failed(let reason):
      guard Self.isValidReason(reason) else { throw TaskCoordinatorError.invalidFailureReason }
      event = .failureRecorded(reason: reason)
      releasesLocks = true
    }
    let aggregate = try TaskReducer.reduce(current.aggregate, event: event)
    let projection = TaskProjection(
      aggregate: aggregate,
      lastSequence: try Self.nextSequence(after: current.lastSequence, taskID: taskID)
    )
    try await append(
      .domain(event),
      taskID: taskID,
      expectedSequence: current.lastSequence,
      releasesOwnedLocks: releasesLocks,
      projection: projection
    )
    return projection
  }

  private func applyApprovalRequest(
    _ approvalID: ApprovalID,
    current: TaskProjection,
    taskID: TaskID,
    binding: ExecutionBinding
  ) async throws -> TaskProjection {
    let requested = TaskEvent.codexApprovalRequested(approvalID)
    guard
      let evidence = try await runtime.approvalEvidence(
        taskID: taskID,
        approvalID: approvalID
      )
    else {
      let aggregate = try TaskReducer.reduce(current.aggregate, event: requested)
      let projection = TaskProjection(
        aggregate: aggregate,
        lastSequence: try Self.nextSequence(after: current.lastSequence, taskID: taskID)
      )
      try await append(
        .domain(requested),
        taskID: taskID,
        expectedSequence: current.lastSequence,
        projection: projection
      )
      return projection
    }
    guard evidence.approvalID == approvalID, evidence.threadID == binding.threadID,
      evidence.turnID == binding.turnID
    else { throw TaskCoordinatorError.corruptTask(taskID) }

    let evidenceEvent = TaskEvent.codexApprovalEvidenceRecorded(evidence)
    let withEvidence = try TaskReducer.reduce(current.aggregate, event: evidenceEvent)
    let aggregate = try TaskReducer.reduce(withEvidence, event: requested)
    let evidenceSequence = try Self.nextSequence(after: current.lastSequence, taskID: taskID)
    let requestSequence = try Self.nextSequence(after: evidenceSequence, taskID: taskID)
    let projection = TaskProjection(aggregate: aggregate, lastSequence: requestSequence)
    let createdAt = Date()
    try await store.appendBatch(
      [
        try envelope(
          .domain(evidenceEvent),
          taskID: taskID,
          sequence: evidenceSequence,
          createdAt: createdAt
        ),
        try envelope(
          .domain(requested),
          taskID: taskID,
          sequence: requestSequence,
          createdAt: createdAt
        ),
      ],
      expectedLastSequence: current.lastSequence,
      snapshot: try stateSnapshot(for: projection)
    )
    return projection
  }

  private func applyWithRetry(
    _ observation: TaskExecutionObservation,
    taskID: TaskID,
    binding: ExecutionBinding
  ) async throws -> TaskProjection? {
    while true {
      do {
        return try await apply(observation, taskID: taskID, binding: binding)
      } catch EventStoreError.optimisticConcurrencyConflict(let conflictedTaskID, _, _) {
        guard conflictedTaskID == taskID else { throw TaskCoordinatorError.corruptTask(taskID) }
        let current = try await task(taskID)
        guard current.aggregate.binding == binding, !current.aggregate.phase.isTerminal else {
          return nil
        }
      }
    }
  }

  private func recordRuntimeFailure(
    _ error: any Error,
    taskID: TaskID,
    expectedBinding: ExecutionBinding?
  ) async throws {
    let reason = "Execution runtime failed: \(String(describing: type(of: error)))"
    let event = TaskEvent.failureRecorded(reason: reason)
    while true {
      let current = try await task(taskID)
      guard !current.aggregate.phase.isTerminal,
        current.aggregate.binding == expectedBinding
      else { return }
      let aggregate = try TaskReducer.reduce(current.aggregate, event: event)
      do {
        try await append(
          .domain(event),
          taskID: taskID,
          expectedSequence: current.lastSequence,
          releasesOwnedLocks: true,
          projection: TaskProjection(
            aggregate: aggregate,
            lastSequence: try Self.nextSequence(after: current.lastSequence, taskID: taskID)
          )
        )
        try? await pipeline?.discardTaskState(taskID: taskID)
        return
      } catch EventStoreError.optimisticConcurrencyConflict(let conflictedTaskID, _, _) {
        guard conflictedTaskID == taskID else { throw TaskCoordinatorError.corruptTask(taskID) }
      }
    }
  }

  private func releaseOwnedLocks(_ taskID: TaskID) async throws {
    let keys = try await store.lockKeysOwned(by: taskID)
    guard !keys.isEmpty else { return }
    guard keys.count == 2 else { throw TaskCoordinatorError.lockStateCorrupt(taskID) }
    try await store.releaseLocks(keys, ownerTaskID: taskID)
  }

  private func ensureLocks(_ requestedKeys: [String], taskID: TaskID) async throws {
    let ownedKeys = try await store.lockKeysOwned(by: taskID)
    if ownedKeys.isEmpty {
      try await store.acquireLocks(requestedKeys, ownerTaskID: taskID)
      return
    }
    guard ownedKeys.count == 2, ownedKeys == requestedKeys.sorted() else {
      throw TaskCoordinatorError.lockStateCorrupt(taskID)
    }
  }

  private func appendDomain(
    _ event: TaskEvent,
    taskID: TaskID,
    releasesOwnedLocks: Bool = false
  ) async throws -> TaskProjection {
    let current = try await task(taskID)
    let aggregate = try TaskReducer.reduce(current.aggregate, event: event)
    let projection = TaskProjection(
      aggregate: aggregate,
      lastSequence: try Self.nextSequence(after: current.lastSequence, taskID: taskID)
    )
    try await append(
      .domain(event),
      taskID: taskID,
      expectedSequence: current.lastSequence,
      releasesOwnedLocks: releasesOwnedLocks,
      projection: projection
    )
    return projection
  }

  private func append(
    _ record: StoredRecord,
    taskID: TaskID,
    expectedSequence: Int64,
    releasesOwnedLocks: Bool = false,
    projection: TaskProjection? = nil
  ) async throws {
    let sequence = try Self.nextSequence(after: expectedSequence, taskID: taskID)
    let event = try envelope(record, taskID: taskID, sequence: sequence, createdAt: Date())
    let snapshot = try projection.map(stateSnapshot)
    if releasesOwnedLocks {
      try await store.appendReleasingOwnedLocks(
        event,
        expectedLastSequence: expectedSequence,
        snapshot: snapshot
      )
      return
    }
    try await store.append(
      event,
      expectedLastSequence: expectedSequence,
      snapshot: snapshot
    )
  }

  private func envelope(
    _ record: StoredRecord,
    taskID: TaskID,
    sequence: Int64,
    createdAt: Date
  ) throws -> TaskEventEnvelope {
    let payload = try encoder.encode(record)
    guard payload.count <= 256 * 1024 else { throw TaskCoordinatorError.submissionTooLarge }
    return TaskEventEnvelope(
      taskID: taskID,
      sequence: sequence,
      schemaVersion: 1,
      source: "bridge.coordinator",
      kind: Self.kind(record),
      severity: "info",
      payload: payload,
      createdAt: createdAt
    )
  }

  private func projectionIfPresent(_ taskID: TaskID) async throws -> TaskProjection? {
    try await projectionIfPresent(taskID, retriesRemaining: 8)
  }

  private func projectionIfPresent(
    _ taskID: TaskID,
    retriesRemaining: Int
  ) async throws -> TaskProjection? {
    let storedSnapshot = try await store.stateSnapshot(for: taskID)
    var aggregate: TaskAggregate?
    var expectedSequence: Int64
    if let storedSnapshot {
      guard storedSnapshot.schemaVersion == 1 else {
        throw TaskCoordinatorError.corruptTask(taskID)
      }
      let projection = try decoder.decode(StoredProjection.self, from: storedSnapshot.payload)
      guard projection.aggregate.id == taskID,
        projection.lastSequence == storedSnapshot.lastEventSequence
      else {
        throw TaskCoordinatorError.corruptTask(taskID)
      }
      aggregate = projection.aggregate
      expectedSequence = try Self.nextSequence(
        after: storedSnapshot.lastEventSequence,
        taskID: taskID
      )
    } else {
      expectedSequence = 1
    }
    var readEvent = false
    while true {
      try Task.checkCancellation()
      let envelopes = try await store.events(
        for: taskID,
        afterSequence: expectedSequence - 1,
        limit: 500
      )
      if envelopes.isEmpty { break }
      readEvent = true
      for envelope in envelopes {
        try Task.checkCancellation()
        guard envelope.sequence == expectedSequence, envelope.schemaVersion == 1 else {
          throw TaskCoordinatorError.corruptTask(taskID)
        }
        expectedSequence = try Self.nextSequence(after: expectedSequence, taskID: taskID)
        let record = try decoder.decode(StoredRecord.self, from: envelope.payload)
        guard envelope.kind == Self.kind(record) else {
          throw TaskCoordinatorError.corruptTask(taskID)
        }
        switch record {
        case .submission(let submission):
          guard aggregate == nil else { throw TaskCoordinatorError.corruptTask(taskID) }
          aggregate = TaskAggregate(id: taskID, submission: submission)
        case .domain(let event):
          guard let current = aggregate else { throw TaskCoordinatorError.corruptTask(taskID) }
          aggregate = try TaskReducer.reduce(current, event: event)
        case .runtimeIntent:
          guard aggregate != nil else { throw TaskCoordinatorError.corruptTask(taskID) }
        case .semantic:
          guard aggregate != nil else { throw TaskCoordinatorError.corruptTask(taskID) }
        case .finalization:
          guard aggregate != nil else { throw TaskCoordinatorError.corruptTask(taskID) }
        }
      }
    }
    guard aggregate != nil || readEvent else { return nil }
    guard let aggregate else { throw TaskCoordinatorError.corruptTask(taskID) }
    let projection = TaskProjection(aggregate: aggregate, lastSequence: expectedSequence - 1)
    guard try await store.lastEventSequence(for: taskID) == projection.lastSequence else {
      guard retriesRemaining > 0 else { throw TaskCoordinatorError.corruptTask(taskID) }
      return try await projectionIfPresent(taskID, retriesRemaining: retriesRemaining - 1)
    }
    if readEvent {
      do {
        try await store.saveStateSnapshot(
          try stateSnapshot(for: projection),
          expectedLastSequence: projection.lastSequence
        )
      } catch EventStoreError.optimisticConcurrencyConflict {
        guard retriesRemaining > 0 else { throw TaskCoordinatorError.corruptTask(taskID) }
        return try await projectionIfPresent(taskID, retriesRemaining: retriesRemaining - 1)
      }
    }
    return projection
  }

  private func stateSnapshot(for projection: TaskProjection) throws -> TaskStateSnapshot {
    let payload = try encoder.encode(
      StoredProjection(
        aggregate: projection.aggregate,
        lastSequence: projection.lastSequence
      )
    )
    guard payload.count <= 512 * 1024 else {
      throw TaskCoordinatorError.submissionTooLarge
    }
    return TaskStateSnapshot(
      taskID: projection.aggregate.id,
      lastEventSequence: projection.lastSequence,
      schemaVersion: 1,
      payload: payload,
      recoveryRequired: Self.requiresRecovery(projection.aggregate.phase)
    )
  }

  private func advancedProjection(_ current: TaskProjection) throws -> TaskProjection {
    TaskProjection(
      aggregate: current.aggregate,
      lastSequence: try Self.nextSequence(
        after: current.lastSequence,
        taskID: current.aggregate.id
      )
    )
  }

  private static func nextSequence(after sequence: Int64, taskID: TaskID) throws -> Int64 {
    let (next, overflow) = sequence.addingReportingOverflow(1)
    guard !overflow else { throw TaskCoordinatorError.corruptTask(taskID) }
    return next
  }

  private static func validate(
    _ preparation: PreparedTaskExecution,
    previousBinding: ExecutionBinding?,
    taskID: TaskID
  ) throws {
    guard isValidIdentifier(preparation.threadID.rawValue), preparation.turnGeneration > 0,
      preparation.lockKeys.count == 2,
      Set(preparation.lockKeys).count == 2,
      preparation.lockKeys.allSatisfy({ isValidLockKey($0) })
    else {
      throw TaskCoordinatorError.corruptTask(taskID)
    }
    if let previousBinding {
      guard previousBinding.threadID == preparation.threadID,
        previousBinding.turnGeneration < UInt64.max,
        preparation.turnGeneration == previousBinding.turnGeneration + 1
      else {
        throw TaskCoordinatorError.corruptTask(taskID)
      }
      return
    }
    guard preparation.turnGeneration == 1 else {
      throw TaskCoordinatorError.corruptTask(taskID)
    }
  }

  private static func isValidLockKey(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private static func validateSubmission(
    _ submission: TaskSubmission,
    decision: TaskAdmissionDecision
  ) throws {
    let aggregate = TaskAggregate(id: TaskID(rawValue: "validation"), submission: submission)
    let event: TaskEvent =
      decision == .requireLocalApproval ? .localApprovalRequested : .preparationStarted
    _ = try TaskReducer.reduce(aggregate, event: event)
  }

  private func submissionIdentity(
    origin: String,
    submission: TaskSubmission
  ) throws -> (origin: String, fingerprint: String) {
    let normalizedOrigin = try Self.validatedOrigin(origin)
    let encodedSubmission = try encoder.encode(submission)
    guard encodedSubmission.count <= 128 * 1024 else {
      throw TaskCoordinatorError.submissionTooLarge
    }
    return (
      normalizedOrigin,
      SHA256.hash(data: encodedSubmission).hexString
    )
  }

  private static func validatedOrigin(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == value, trimmed.utf8.count <= 64,
      trimmed.utf8.allSatisfy({ byte in
        byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
          || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
          || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
      })
    else {
      throw TaskCoordinatorError.invalidOrigin
    }
    return trimmed
  }

  private static func finalizationRecord(
    _ authorization: TaskFinalizationAuthorization
  ) throws -> TaskFinalizationRecord {
    let kind: String
    let detail: String
    switch authorization {
    case .supervisorFinalAccept(let decisionID):
      kind = "supervisor_final_accept"
      detail = decisionID
    case .userOverride(let reason):
      kind = "user_override"
      detail = reason
    }
    let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized == detail, normalized.utf8.count <= 2_048 else {
      throw TaskCoordinatorError.invalidFinalizationAuthorization
    }
    return TaskFinalizationRecord(kind: kind, detail: detail, pipelineReservation: nil)
  }

  private func storedPipelineReservation(
    after sequence: Int64,
    taskID: TaskID
  ) async throws -> TaskPipelineFinalizationReservation? {
    guard
      let envelope = try await store.events(
        for: taskID,
        afterSequence: sequence,
        limit: 1
      ).first
    else { return nil }
    let record = try decoder.decode(StoredRecord.self, from: envelope.payload)
    guard envelope.kind == Self.kind(record), case .finalization(let finalization) = record else {
      return nil
    }
    return finalization.pipelineReservation
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy(Set("0123456789abcdef").contains)
  }

  private static func kind(_ record: StoredRecord) -> String {
    switch record {
    case .submission: "task.submission"
    case .domain(let event): "task.\(event.kind)"
    case .runtimeIntent: "task.runtimeIntent"
    case .semantic: "task.semantic"
    case .finalization: "task.finalizationAuthorization"
    }
  }

  private static func requiresRecovery(_ phase: TaskPhase) -> Bool {
    [.preparing, .running, .awaitingCodexApproval, .verifying, .recovering].contains(phase)
  }

  private static func isValidReason(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && value.utf8.count <= 4_096
      && !value.contains("\0")
  }

  private static func isValidIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0")
  }

  private static func randomIdentifier() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}

extension SHA256.Digest {
  fileprivate var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
