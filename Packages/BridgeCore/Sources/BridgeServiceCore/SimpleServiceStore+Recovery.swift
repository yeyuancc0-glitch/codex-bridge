import Foundation
import GRDB

extension SimpleServiceStore {
  @discardableResult
  public func markIncompleteTasksUnknown(at date: Date) throws -> [ServiceTaskRecord] {
    try ServiceValidation.date(date, field: "recovery.date")
    do {
      return try database.write { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM bridge_service_tasks
            WHERE status IN (
              'awaiting_local_approval', 'starting', 'running', 'waiting_for_codex_approval'
            )
            ORDER BY created_at, task_id
            """
        )
        var updated: [ServiceTaskRecord] = []
        updated.reserveCapacity(rows.count)
        for row in rows {
          let task = try Self.decodeTask(row)
          if task.state.status == .awaitingLocalApproval,
            task.requiresLocalStartApproval
          {
            continue
          }
          let wasNotStarted = task.state.status == .awaitingLocalApproval
          let recoveredStatus: ServiceTaskStatus = wasNotStarted ? .interrupted : .unknown
          let supervisorStatus: ServiceSupervisorStatus =
            task.state.supervisorStatus == .disabled ? .disabled : .degraded
          let state = try ServiceTaskState(
            codexThreadID: task.state.codexThreadID,
            codexTurnID: task.state.codexTurnID,
            providerSessionID: task.state.providerSessionID,
            providerRunID: task.state.providerRunID,
            status: recoveredStatus,
            supervisorStatus: supervisorStatus,
            currentStep: task.state.currentStep,
            changedFiles: task.state.changedFiles,
            resultSummary: task.state.resultSummary,
            supervisorSummary: task.state.supervisorSummary,
            failureCode: task.state.failureCode
          )
          let recovered = try task.replacingState(state, updatedAt: date)
          try Self.validateTransition(from: task.state.status, to: recoveredStatus)
          try updateTaskRow(recovered, in: db)
          try Self.insert(
            ServiceTaskEventDraft(
              kind: wasNotStarted ? .taskInterrupted : .taskMarkedUnknown,
              summary: wasNotStarted
                ? "The service restarted before task execution began."
                : "The service restarted without an attached provider run.",
              createdAt: date
            ),
            taskID: task.id,
            in: db
          )
          updated.append(recovered)
        }
        return updated
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
