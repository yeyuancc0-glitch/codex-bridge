import BridgeDomain
import BridgeServiceCore
import BridgeSupervisor

actor ServiceSupervisorCoordinator {
  private let tasks: ServiceTaskManager
  private let execution: ExecutionManager
  private let supervisor: SupervisorManager?
  private let conversation: TaskConversationBuffer

  private var collectors: [TaskID: Task<Void, Never>] = [:]
  private var isShuttingDown = false

  init(
    tasks: ServiceTaskManager,
    execution: ExecutionManager,
    supervisor: SupervisorManager?,
    conversation: TaskConversationBuffer
  ) {
    self.tasks = tasks
    self.execution = execution
    self.supervisor = supervisor
    self.conversation = conversation
  }

  func launch(task: ServiceTaskRecord) async {
    guard let supervisor, !isShuttingDown else { return }
    do {
      guard let handle = try await supervisor.launch(task: task) else { return }
      guard !isShuttingDown else {
        await supervisor.stop(taskID: task.id)
        return
      }
      let events = handle.events
      // Supervisor state transitions must not starve behind ambient task load.
      collectors[task.id] = Task(priority: .userInitiated) { [weak self] in
        for await event in events {
          guard let self else { return }
          await self.consume(event, taskID: task.id)
        }
        await self?.collectorFinished(task.id)
      }
    } catch {
      _ = try? await tasks.updateSupervisor(
        taskID: task.id,
        status: .degraded,
        summary: "Supervisor could not start; Codex execution continues."
      )
    }
  }

  func observe(
    task: ServiceTaskRecord,
    kind: SupervisorObservationKind,
    summary: String
  ) async {
    guard let supervisor else { return }
    let observation = try? SupervisorObservation(
      kind: kind,
      taskID: task.id,
      goal: task.prompt,
      currentStep: task.state.currentStep,
      summary: summary,
      changedFiles: task.state.changedFiles,
      resultSummary: task.state.resultSummary
    )
    guard let observation else {
      _ = try? await tasks.updateSupervisor(
        taskID: task.id,
        status: .degraded,
        summary: "Supervisor observation validation failed; Codex execution continues."
      )
      return
    }
    await supervisor.observe(observation)
  }

  func stop(taskID: TaskID) async {
    collectors.removeValue(forKey: taskID)?.cancel()
    await supervisor?.stop(taskID: taskID)
  }

  func beginShutdown() {
    isShuttingDown = true
    let runningCollectors = collectors.values
    collectors.removeAll(keepingCapacity: false)
    for collector in runningCollectors {
      collector.cancel()
    }
  }

  func shutdown() async {
    beginShutdown()
    await supervisor?.shutdown()
  }

  private func consume(_ event: SupervisorEvent, taskID: TaskID) async {
    switch event {
    case .started:
      _ = try? await tasks.updateSupervisor(taskID: taskID, status: .running, summary: nil)

    case .decision(let decision):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .running,
        summary: decision.summary
      )

    case .steer(let instruction, let summary):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .running,
        summary: summary
      )
      await applySteer(taskID: taskID, instruction: instruction)

    case .attention(let summary):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .running,
        summary: summary
      )

    case .completed(let summary):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .completed,
        summary: summary
      )

    case .degraded(_, let summary):
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .degraded,
        summary: summary
      )
    }
  }

  private func applySteer(taskID: TaskID, instruction: String) async {
    do {
      guard let task = try await tasks.task(id: taskID) else {
        throw ServiceStoreError.unknownTask(taskID)
      }
      guard task.state.status == .running, let turnID = task.state.codexTurnID else {
        throw ExecutionServiceError.sessionUnavailable(taskID)
      }
      try await execution.steer(
        taskID: taskID,
        expectedTurnID: turnID,
        text: instruction
      )
      await conversation.appendUserMessage(taskID: taskID, content: instruction)
    } catch {
      _ = try? await tasks.updateSupervisor(
        taskID: taskID,
        status: .degraded,
        summary: "Supervisor steer could not be applied; Codex execution continues."
      )
    }
  }

  private func collectorFinished(_ taskID: TaskID) {
    collectors[taskID] = nil
  }
}
