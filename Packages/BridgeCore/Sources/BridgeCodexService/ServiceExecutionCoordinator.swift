import BridgeDomain
import BridgeServiceCore
import Foundation

public actor ServiceExecutionCoordinator {
  private let tasks: ServiceTaskManager
  private let projects: ServiceProjectService
  private let execution: ExecutionManager
  private var collectors: [TaskID: Task<Void, Never>] = [:]

  public init(
    tasks: ServiceTaskManager,
    projects: ServiceProjectService,
    execution: ExecutionManager
  ) {
    self.tasks = tasks
    self.projects = projects
    self.execution = execution
  }

  @discardableResult
  public func start(taskID: TaskID) async throws -> ExecutionBinding {
    guard collectors[taskID] == nil else {
      throw ExecutionServiceError.activeSession(taskID)
    }
    guard let task = try await tasks.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    guard let project = try await projects.project(id: task.projectID) else {
      throw ExecutionServiceError.projectUnavailable(task.projectID)
    }

    let handle: ExecutionHandle
    do {
      handle = try await execution.start(try ExecutionRequest(task: task, project: project))
      _ = try await tasks.markExecutionStarted(
        taskID: taskID,
        threadID: handle.binding.threadID,
        turnID: handle.binding.turnID
      )
    } catch {
      await execution.stop(taskID: taskID)
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "execution_start_failed",
        summary: "Codex could not start the task."
      )
      throw error
    }

    let events = handle.events
    collectors[taskID] = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.consume(event, taskID: taskID)
      }
      await self?.collectorFinished(taskID)
    }
    return handle.binding
  }

  public func steer(
    taskID: TaskID,
    expectedTurnID: String,
    text: String
  ) async throws {
    try await execution.steer(
      taskID: taskID,
      expectedTurnID: expectedTurnID,
      text: text
    )
  }

  public func interrupt(
    taskID: TaskID,
    expectedTurnID: String? = nil
  ) async throws {
    try await execution.interrupt(taskID: taskID, expectedTurnID: expectedTurnID)
  }

  public func pendingApprovals(taskID: TaskID? = nil) async -> [ExecutionApprovalRequest] {
    await execution.pendingApprovals(taskID: taskID)
  }

  public func resolveApproval(
    taskID: TaskID,
    approvalID: String,
    decision: LocalApprovalDecision
  ) async throws {
    try await execution.respondToApproval(
      taskID: taskID,
      approvalID: approvalID,
      decision: decision
    )
    do {
      _ = try await tasks.resumeAfterCodexApproval(
        taskID: taskID,
        approved: decision == .allow
      )
      await execution.finalizeApproval(
        taskID: taskID,
        approvalID: approvalID,
        committed: true
      )
    } catch {
      await execution.finalizeApproval(
        taskID: taskID,
        approvalID: approvalID,
        committed: false
      )
      throw error
    }
  }

  public func stop(taskID: TaskID, summary: String = "The local service stopped the task.") async {
    collectors.removeValue(forKey: taskID)?.cancel()
    await execution.stop(taskID: taskID)
    _ = try? await tasks.interrupt(taskID: taskID, summary: summary)
  }

  public func shutdown() async {
    let active = collectors
    collectors.removeAll(keepingCapacity: false)
    for task in active.values {
      task.cancel()
    }
    await execution.shutdown()
  }

  private func consume(_ event: ExecutionEvent, taskID: TaskID) async {
    do {
      switch event {
      case .planUpdated(let currentStep, _):
        _ = try await tasks.updatePlan(taskID: taskID, currentStep: currentStep)

      case .commandCompleted(let displayCommand, let exitCode, let status):
        let exit = exitCode.map { " (exit \($0))" } ?? ""
        _ = try await tasks.recordCommandCompletion(
          taskID: taskID,
          summary: "Codex command \(status.rawValue)\(exit): \(displayCommand)"
        )

      case .filesChanged(let relativePaths, let status):
        let changed = status == .completed ? relativePaths : []
        _ = try await tasks.recordChangedFiles(
          taskID: taskID,
          relativePaths: changed,
          summary: "Codex file change \(status.rawValue) for \(relativePaths.count) path(s)."
        )

      case .approvalRequested:
        _ = try await tasks.markWaitingForCodexApproval(taskID: taskID)

      case .completed(let resultSummary):
        let current = try await requiredTask(taskID)
        _ = try await tasks.complete(
          taskID: taskID,
          resultSummary: resultSummary,
          changedFiles: current.state.changedFiles
        )

      case .interrupted:
        _ = try await tasks.interrupt(
          taskID: taskID,
          summary: "Codex confirmed that the active Turn was interrupted."
        )

      case .failed(let code, let summary):
        _ = try await tasks.fail(taskID: taskID, failureCode: code, summary: summary)
      }
    } catch {
      await execution.stop(taskID: taskID)
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "execution_state_update_failed",
        summary: "The service could not persist Codex task progress."
      )
    }
  }

  private func requiredTask(_ taskID: TaskID) async throws -> ServiceTaskRecord {
    guard let task = try await tasks.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    return task
  }

  private func collectorFinished(_ taskID: TaskID) {
    collectors[taskID] = nil
  }
}
