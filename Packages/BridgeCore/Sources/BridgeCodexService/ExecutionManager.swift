import BridgeDomain
import Foundation

public actor ExecutionManager {
  private let configuration: ExecutionManagerConfiguration
  private var sessions: [TaskID: ExecutionSession] = [:]

  public init(configuration: ExecutionManagerConfiguration) {
    self.configuration = configuration
  }

  public func start(_ request: ExecutionRequest) async throws -> ExecutionHandle {
    let taskID = request.task.id
    guard sessions[taskID] == nil else {
      throw ExecutionServiceError.activeSession(taskID)
    }
    guard sessions.count < configuration.maximumConcurrentSessions else {
      throw ExecutionServiceError.sessionLimitReached
    }

    let session = ExecutionSession(
      taskID: taskID,
      configuration: configuration,
      projectRoot: request.project.root.canonicalPath,
      onTermination: { [weak self] taskID, session in
        await self?.remove(taskID: taskID, matching: session)
      }
    )
    sessions[taskID] = session
    do {
      let binding = try await session.start(request)
      guard sessions[taskID] === session else {
        throw ExecutionServiceError.sessionUnavailable(taskID)
      }
      return ExecutionHandle(taskID: taskID, binding: binding, events: session.events)
    } catch {
      if sessions[taskID] === session {
        sessions[taskID] = nil
      }
      await session.shutdown()
      throw error
    }
  }

  public func steer(
    taskID: TaskID,
    expectedTurnID: String,
    text: String
  ) async throws {
    let session = try requiredSession(taskID)
    try await session.steer(expectedTurnID: expectedTurnID, text: text)
  }

  public func interrupt(
    taskID: TaskID,
    expectedTurnID: String? = nil
  ) async throws {
    let session = try requiredSession(taskID)
    try await session.interrupt(expectedTurnID: expectedTurnID)
  }

  public func pendingApprovals(taskID: TaskID? = nil) async -> [ExecutionApprovalRequest] {
    if let taskID {
      guard let session = sessions[taskID] else { return [] }
      return await session.pendingApprovalRequests()
    }
    var result: [ExecutionApprovalRequest] = []
    for session in sessions.values {
      result.append(contentsOf: await session.pendingApprovalRequests())
    }
    return result.sorted { lhs, rhs in
      lhs.taskID.rawValue == rhs.taskID.rawValue
        ? lhs.id < rhs.id
        : lhs.taskID.rawValue < rhs.taskID.rawValue
    }
  }

  public func respondToApproval(
    taskID: TaskID,
    approvalID: String,
    decision: LocalApprovalDecision
  ) async throws {
    let session = try requiredSession(taskID)
    try await session.respondToApproval(id: approvalID, decision: decision)
  }

  public func finalizeApproval(
    taskID: TaskID,
    approvalID: String,
    committed: Bool
  ) async {
    guard let session = sessions[taskID] else { return }
    await session.finalizeApproval(id: approvalID, committed: committed)
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

  private func requiredSession(_ taskID: TaskID) throws -> ExecutionSession {
    guard let session = sessions[taskID] else {
      throw ExecutionServiceError.sessionUnavailable(taskID)
    }
    return session
  }

  private func remove(taskID: TaskID, matching session: ExecutionSession) {
    if sessions[taskID] === session {
      sessions[taskID] = nil
    }
  }
}
