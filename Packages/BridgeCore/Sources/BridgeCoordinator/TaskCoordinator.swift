import BridgeDomain
import BridgePersistence
import CryptoKit
import Foundation

public actor TaskCoordinator {
  private enum StoredRecord: Codable {
    case submission(TaskSubmission)
    case domain(TaskEvent)
    case runtimeIntent(TaskRuntimeIntentRecord)
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
  }

  private let store: EventStore
  private let admission: any TaskAdmissionPolicy
  private let runtime: any TaskExecutionRuntime
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()
  private var workers: [TaskID: Task<Void, Never>] = [:]
  private var pendingStarts: Set<TaskID> = []

  public init(
    store: EventStore,
    admission: any TaskAdmissionPolicy,
    runtime: any TaskExecutionRuntime
  ) {
    self.store = store
    self.admission = admission
    self.runtime = runtime
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
    let normalizedOrigin = try Self.validatedOrigin(origin)
    let encodedSubmission = try encoder.encode(submission)
    guard encodedSubmission.count <= 128 * 1024 else {
      throw TaskCoordinatorError.submissionTooLarge
    }
    let fingerprint = SHA256.hash(data: encodedSubmission).hexString
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
    let taskID = try await store.claimSubmission(
      origin: normalizedOrigin,
      key: submission.idempotencyKey,
      requestFingerprint: fingerprint,
      taskID: candidate,
      initialEvents: initialEvents,
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
    let current = try await task(taskID)
    guard current.aggregate.pendingApprovalIDs.contains(approvalID) else {
      throw TaskTransitionError.approvalNotPending(approvalID)
    }
    guard Self.isValidIdentifier(approvalID.rawValue) else {
      throw TaskCoordinatorError.invalidApprovalIdentifier
    }
    let intent = TaskRuntimeIntentRecord(
      kind: "resolve_codex_approval",
      identifier: approvalID.rawValue,
      approved: approved,
      detail: nil
    )
    try await append(
      .runtimeIntent(intent),
      taskID: taskID,
      expectedSequence: current.lastSequence
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
      try? await recordRuntimeFailure(
        error,
        taskID: taskID,
        expectedBinding: current.aggregate.binding
      )
      throw error
    }
  }

  public func interrupt(taskID: TaskID, reason: String? = nil) async throws -> TaskProjection {
    try await interruptWithResult(taskID: taskID, reason: reason).projection
  }

  public func interruptWithResult(
    taskID: TaskID,
    reason: String? = nil
  ) async throws -> TaskMutationResult {
    try await requestStop(taskID: taskID, outcome: .interrupt, reason: reason)
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
      expectedSequence: current.lastSequence
    )
    do {
      try await runtime.steer(taskID: taskID, binding: binding, prompt: normalized)
      return TaskMutationResult(
        projection: try await task(taskID),
        operationID: operationID
      )
    } catch {
      try? await recordRuntimeFailure(error, taskID: taskID, expectedBinding: binding)
      throw error
    }
  }

  public func suspend(taskID: TaskID, reason: String? = nil) async throws -> TaskProjection {
    try await requestStop(taskID: taskID, outcome: .suspend, reason: reason).projection
  }

  public func resume(taskID: TaskID) async throws -> TaskProjection {
    let projection = try await appendDomain(.resumeRequested, taskID: taskID)
    requestStart(taskID)
    return projection
  }

  private func requestStop(
    taskID: TaskID,
    outcome: StopIntent.Outcome,
    reason: String?
  ) async throws -> TaskMutationResult {
    let current = try await task(taskID)
    guard let binding = current.aggregate.binding else {
      throw TaskCoordinatorError.executionUnavailable(taskID)
    }
    let intent = StopIntent(
      operationID: OperationID(rawValue: "op_\(Self.randomIdentifier())"),
      outcome: outcome,
      reason: reason
    )
    let projection = try await appendDomain(.stopRequested(intent), taskID: taskID)
    do {
      try await runtime.interrupt(taskID: taskID, binding: binding)
      return TaskMutationResult(projection: projection, operationID: intent.operationID)
    } catch {
      try? await recordRuntimeFailure(error, taskID: taskID, expectedBinding: binding)
      throw error
    }
  }

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
    _ = try TaskReducer.reduce(
      current.aggregate,
      event: .finalReportStored(reference: reference)
    )
    try await append(
      .finalization(record),
      taskID: taskID,
      expectedSequence: current.lastSequence
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

  public func recoverIncompleteTasks() async throws -> [TaskProjection] {
    var recovered: [TaskProjection] = []
    for taskID in try await store.taskIDs() {
      var current = try await task(taskID)
      if current.aggregate.phase.isTerminal {
        try await releaseOwnedLocks(taskID)
        continue
      }
      guard Self.requiresRecovery(current.aggregate.phase) else { continue }
      current = try await appendDomain(.recoveryStarted, taskID: taskID)
      current = try await appendDomain(.recoveryAmbiguous, taskID: taskID)
      recovered.append(current)
    }
    return recovered
  }

  public func resolveRecovery(taskID: TaskID, to phase: TaskPhase) async throws -> TaskProjection {
    let current = try await task(taskID)
    guard current.aggregate.phase == .recovering else {
      throw TaskCoordinatorError.recoveryRequiresReconciliation(current.aggregate.phase)
    }
    let releasesLocks = phase.isTerminal || phase == .suspended
    let projection = try await appendDomain(
      .recoveryResolved(to: phase),
      taskID: taskID,
      releasesOwnedLocks: releasesLocks
    )
    if phase == .preparing { requestStart(taskID) }
    return projection
  }

  public func beginRecoveryReconciliation(taskID: TaskID) async throws -> TaskProjection {
    let current = try await task(taskID)
    guard current.aggregate.phase == .unknown else {
      throw TaskCoordinatorError.recoveryRequiresReconciliation(current.aggregate.phase)
    }
    return try await appendDomain(.recoveryStarted, taskID: taskID)
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
        let session = try await runtime.start(
          taskID: taskID,
          submission: current.aggregate.submission,
          previousBinding: current.aggregate.binding
        )
        startedBinding = session.binding
        _ = try await appendDomain(.turnStarted(session.binding), taskID: taskID)
        failureBinding = session.binding
        await consume(session.observations, taskID: taskID, binding: session.binding)
      } catch {
        if let startedBinding {
          try? await runtime.interrupt(taskID: taskID, binding: startedBinding)
        }
        try? await recordRuntimeFailure(
          error,
          taskID: taskID,
          expectedBinding: failureBinding
        )
      }
    } catch {
      try? await recordRuntimeFailure(
        error,
        taskID: taskID,
        expectedBinding: failureBinding
      )
    }
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
      do {
        guard try await applyWithRetry(observation, taskID: taskID, binding: binding) else {
          return
        }
      } catch {
        try? await recordRuntimeFailure(error, taskID: taskID, expectedBinding: binding)
        return
      }
      switch observation {
      case .turnCompleted, .turnStopped, .failed:
        return
      case .codexApprovalRequested:
        break
      }
      guard let phase = try? await task(taskID).aggregate.phase else { return }
      if phase.isTerminal || phase == .suspended || phase == .verifying { return }
    }
    guard let projection = try? await task(taskID) else { return }
    let phase = projection.aggregate.phase
    guard !phase.isTerminal, phase != .suspended, phase != .verifying else { return }
    try? await recordRuntimeFailure(
      TaskCoordinatorError.executionUnavailable(taskID),
      taskID: taskID,
      expectedBinding: binding
    )
  }

  private func apply(
    _ observation: TaskExecutionObservation,
    taskID: TaskID,
    binding: ExecutionBinding
  ) async throws -> Bool {
    let current = try await task(taskID)
    guard current.aggregate.binding == binding else { return false }
    let event: TaskEvent
    let releasesLocks: Bool
    switch observation {
    case .codexApprovalRequested(let approvalID):
      guard Self.isValidIdentifier(approvalID.rawValue) else {
        throw TaskCoordinatorError.invalidApprovalIdentifier
      }
      event = .codexApprovalRequested(approvalID)
      releasesLocks = false
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
    _ = try TaskReducer.reduce(current.aggregate, event: event)
    try await append(
      .domain(event),
      taskID: taskID,
      expectedSequence: current.lastSequence,
      releasesOwnedLocks: releasesLocks
    )
    return true
  }

  private func applyWithRetry(
    _ observation: TaskExecutionObservation,
    taskID: TaskID,
    binding: ExecutionBinding
  ) async throws -> Bool {
    while true {
      do {
        return try await apply(observation, taskID: taskID, binding: binding)
      } catch EventStoreError.optimisticConcurrencyConflict(let conflictedTaskID, _, _) {
        guard conflictedTaskID == taskID else { throw TaskCoordinatorError.corruptTask(taskID) }
        let current = try await task(taskID)
        guard current.aggregate.binding == binding, !current.aggregate.phase.isTerminal else {
          return false
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
      _ = try TaskReducer.reduce(current.aggregate, event: event)
      do {
        try await append(
          .domain(event),
          taskID: taskID,
          expectedSequence: current.lastSequence,
          releasesOwnedLocks: true
        )
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
    _ = try TaskReducer.reduce(current.aggregate, event: event)
    try await append(
      .domain(event),
      taskID: taskID,
      expectedSequence: current.lastSequence,
      releasesOwnedLocks: releasesOwnedLocks
    )
    return try await task(taskID)
  }

  private func append(
    _ record: StoredRecord,
    taskID: TaskID,
    expectedSequence: Int64,
    releasesOwnedLocks: Bool = false
  ) async throws {
    let sequence = expectedSequence + 1
    let event = try envelope(record, taskID: taskID, sequence: sequence, createdAt: Date())
    if releasesOwnedLocks {
      try await store.appendReleasingOwnedLocks(
        event,
        expectedLastSequence: expectedSequence
      )
      return
    }
    try await store.append(event, expectedLastSequence: expectedSequence)
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
    let envelopes = try await store.events(for: taskID)
    guard !envelopes.isEmpty else { return nil }
    var aggregate: TaskAggregate?
    var expectedSequence: Int64 = 1
    for envelope in envelopes {
      guard envelope.sequence == expectedSequence, envelope.schemaVersion == 1 else {
        throw TaskCoordinatorError.corruptTask(taskID)
      }
      expectedSequence += 1
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
      case .finalization:
        guard aggregate != nil else { throw TaskCoordinatorError.corruptTask(taskID) }
      }
    }
    guard let aggregate else { throw TaskCoordinatorError.corruptTask(taskID) }
    return TaskProjection(aggregate: aggregate, lastSequence: expectedSequence - 1)
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
    return TaskFinalizationRecord(kind: kind, detail: detail)
  }

  private static func kind(_ record: StoredRecord) -> String {
    switch record {
    case .submission: "task.submission"
    case .domain(let event): "task.\(event.kind)"
    case .runtimeIntent: "task.runtimeIntent"
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
