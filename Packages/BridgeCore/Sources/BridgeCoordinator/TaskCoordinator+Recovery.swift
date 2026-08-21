import BridgeDomain
import BridgePersistence
import Foundation

extension TaskCoordinator {
  public func reconcileActiveTasksAfterWake() async throws -> [TaskProjection] {
    var reconciled: [TaskProjection] = []
    var cursor: TaskID?
    var inspected = 0
    while true {
      try Task.checkCancellation()
      let taskIDs = try await store.taskIDsWithActiveSnapshots(afterTaskID: cursor, limit: 200)
      guard !taskIDs.isEmpty else { break }
      guard inspected <= 2_048 - taskIDs.count else {
        throw TaskCoordinatorError.executionUnavailable(taskIDs[0])
      }
      inspected += taskIDs.count
      for taskID in taskIDs {
        try Task.checkCancellation()
        let current = try await task(taskID)
        guard
          current.aggregate.phase == .running
            || current.aggregate.phase == .awaitingCodexApproval,
          let binding = current.aggregate.binding
        else { continue }
        let result: TaskExecutionReconciliationResult
        do {
          result = try await runtime.reconcile(
            taskID: taskID,
            submission: current.aggregate.submission,
            binding: binding
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          result = .ambiguous
        }
        let latest = try await task(taskID)
        guard latest.lastSequence == current.lastSequence,
          latest.aggregate.binding == binding,
          latest.aggregate.phase == current.aggregate.phase
        else { continue }
        guard case .observed(let observedBinding, let status) = result else {
          if let ambiguous = try await markRecoveryAmbiguous(latest) {
            reconciled.append(ambiguous)
          }
          continue
        }
        guard observedBinding == binding else {
          if let ambiguous = try await markRecoveryAmbiguous(latest) {
            reconciled.append(ambiguous)
          }
          continue
        }
        switch status {
        case .attached:
          break
        case .observedRunning:
          if let ambiguous = try await markRecoveryAmbiguous(latest) {
            reconciled.append(ambiguous)
          }
        case .completed:
          reconciled.append(try await recoverCompletedTurn(latest))
        case .interrupted:
          reconciled.append(try await recoverInterruptedTurn(latest))
        case .failed:
          reconciled.append(
            try await recordRecoveryFailure(
              latest,
              reason: "Codex reported that the active turn failed during sleep."
            )
          )
        case .invalidated:
          do {
            try await runtime.abortSession(taskID: taskID, binding: binding)
          } catch {
            continue
          }
          let stopped = try await task(taskID)
          guard stopped.lastSequence == latest.lastSequence,
            stopped.aggregate.binding == binding
          else { continue }
          reconciled.append(
            try await recordRecoveryFailure(
              stopped,
              reason: "The registered execution root or policy changed during sleep."
            )
          )
        }
      }
      cursor = taskIDs.last
    }
    return reconciled
  }

  func reconcileRecovery(_ original: TaskProjection) async throws -> TaskProjection? {
    guard let binding = original.aggregate.binding, original.aggregate.phase != .preparing else {
      return try await markRecoveryAmbiguous(original)
    }
    let result: TaskExecutionReconciliationResult
    do {
      result = try await runtime.reconcile(
        taskID: original.aggregate.id,
        submission: original.aggregate.submission,
        binding: binding
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return try await markRecoveryAmbiguous(original)
    }
    let current = try await task(original.aggregate.id)
    guard current.lastSequence == original.lastSequence,
      current.aggregate.phase == original.aggregate.phase,
      current.aggregate.binding == binding
    else {
      throw EventStoreError.optimisticConcurrencyConflict(
        taskID: original.aggregate.id,
        expectedLastSequence: original.lastSequence,
        actualLastSequence: current.lastSequence
      )
    }
    guard case .observed(let observedBinding, let status) = result,
      observedBinding == binding
    else { return try await markRecoveryAmbiguous(current) }
    switch status {
    case .attached:
      return nil
    case .observedRunning:
      return try await markRecoveryAmbiguous(current)
    case .completed:
      return try await recoverCompletedTurn(current)
    case .interrupted:
      return try await recoverInterruptedTurn(current)
    case .failed:
      return try await recordRecoveryFailure(
        current,
        reason: "Codex reported that the persisted turn failed while Bridge was offline."
      )
    case .invalidated:
      return try await recordRecoveryFailure(
        current,
        reason: "The registered execution root or policy changed while Bridge was offline."
      )
    }
  }

  func recoverCompletedTurn(_ current: TaskProjection) async throws -> TaskProjection {
    guard current.aggregate.pendingApprovalIDs.isEmpty,
      current.aggregate.resolvingApprovalIDs.isEmpty,
      current.aggregate.approvalEvidenceByID.isEmpty
    else {
      return try await recordRecoveryFailure(
        current,
        reason: "Codex completed with an unresolved approval while Bridge was offline."
      )
    }
    let verifying: TaskProjection
    switch current.aggregate.phase {
    case .running, .awaitingCodexApproval:
      verifying = try await commitRecoveryEvents([.turnCompleted], current: current)
    case .recovering, .unknown:
      verifying = try await commitRecoveryResolution(.verifying, current: current)
    case .verifying:
      verifying = current
    default:
      return try await markRecoveryAmbiguous(current) ?? current
    }
    do {
      try await pipeline?.finalizeVerifyingTask(
        TaskPipelineVerifyingContext(projection: verifying)
      )
      return try await task(verifying.aggregate.id)
    } catch {
      guard let binding = verifying.aggregate.binding else { throw error }
      return try await failPipelineRecovery(
        taskID: verifying.aggregate.id,
        expectedBinding: binding,
        expectedSequence: verifying.lastSequence
      )
    }
  }

  func recoverInterruptedTurn(_ current: TaskProjection) async throws -> TaskProjection {
    guard let intent = current.aggregate.stopIntent else {
      return try await recordRecoveryFailure(
        current,
        reason: "Codex reported an unexpected interruption while Bridge was offline."
      )
    }
    let projection: TaskProjection
    switch current.aggregate.phase {
    case .running, .awaitingCodexApproval:
      projection = try await commitRecoveryEvents(
        [.turnStopped],
        current: current,
        releasesOwnedLocks: true
      )
    case .recovering, .unknown:
      let target: TaskPhase = intent.outcome == .suspend ? .suspended : .interrupted
      projection = try await commitRecoveryResolution(
        target,
        current: current,
        releasesOwnedLocks: true
      )
    default:
      return try await markRecoveryAmbiguous(current) ?? current
    }
    try await pipeline?.discardTaskState(taskID: current.aggregate.id)
    return projection
  }

  func recordRecoveryFailure(
    _ current: TaskProjection,
    reason: String
  ) async throws -> TaskProjection {
    let projection = try await commitRecoveryEvents(
      [.failureRecorded(reason: reason)],
      current: current,
      releasesOwnedLocks: true
    )
    try await pipeline?.discardTaskState(taskID: current.aggregate.id)
    return projection
  }

  func markRecoveryAmbiguous(_ current: TaskProjection) async throws -> TaskProjection? {
    switch current.aggregate.phase {
    case .unknown:
      return nil
    case .recovering:
      return try await commitRecoveryEvents([.recoveryAmbiguous], current: current)
    default:
      return try await commitRecoveryEvents(
        [.recoveryStarted, .recoveryAmbiguous],
        current: current
      )
    }
  }

  func commitRecoveryResolution(
    _ target: TaskPhase,
    current: TaskProjection,
    releasesOwnedLocks: Bool = false
  ) async throws -> TaskProjection {
    let events: [TaskEvent] =
      current.aggregate.phase == .recovering
      ? [.recoveryResolved(to: target)]
      : [.recoveryStarted, .recoveryResolved(to: target)]
    return try await commitRecoveryEvents(
      events,
      current: current,
      releasesOwnedLocks: releasesOwnedLocks
    )
  }
}
