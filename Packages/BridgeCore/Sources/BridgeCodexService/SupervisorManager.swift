import BridgeDomain
import BridgeServiceCore
import Foundation

public actor SupervisorManager {
  private let configuration: SupervisorManagerConfiguration
  private var sessions: [TaskID: SupervisorSession] = [:]

  public init(configuration: SupervisorManagerConfiguration) {
    self.configuration = configuration
  }

  public func launch(task: ServiceTaskRecord) async throws -> SupervisorHandle? {
    guard let model = task.supervisorModel, let effort = task.supervisorEffort else {
      return nil
    }
    #if os(Windows)
      throw SupervisorServiceError.processUnavailable
    #endif
    guard sessions[task.id] == nil else {
      throw SupervisorServiceError.activeSession(task.id)
    }
    guard sessions.count < configuration.maximumConcurrentSessions else {
      throw SupervisorServiceError.sessionLimitReached
    }
    let session = SupervisorSession(
      taskID: task.id,
      model: model,
      effort: effort,
      goal: task.prompt,
      configuration: configuration,
      onTermination: { [weak self] taskID, session in
        await self?.remove(taskID: taskID, matching: session)
      }
    )
    sessions[task.id] = session
    await session.launch()
    return SupervisorHandle(taskID: task.id, events: session.events)
  }

  public func observe(_ observation: SupervisorObservation) async {
    guard let session = sessions[observation.taskID] else { return }
    await session.observe(observation)
  }

  public func stop(taskID: TaskID) async {
    guard let session = sessions.removeValue(forKey: taskID) else { return }
    await session.shutdown()
  }

  public func shutdown() async {
    let active = Array(sessions.values)
    sessions.removeAll(keepingCapacity: false)
    for session in active {
      await session.shutdown()
    }
  }

  public func hasActiveSession(taskID: TaskID) -> Bool {
    sessions[taskID] != nil
  }

  private func remove(taskID: TaskID, matching session: SupervisorSession) {
    if sessions[taskID] === session {
      sessions[taskID] = nil
    }
  }
}
