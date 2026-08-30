import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceSteerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    mode: MCPTaskSteerMode,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt {
    try Self.checkDeadline(deadline)
    let id = TaskID(rawValue: taskID)
    guard let task = try await tasks.task(id: id) else {
      throw BridgeMCPQueryError.taskNotFound
    }
    guard task.state.status == .running else {
      throw BridgeMCPQueryError.turnMismatch
    }
    if task.providerID != serviceCodexProviderID {
      guard
        ServiceAgentProviderPolicyRegistry.policy(
          for: AgentProviderID(rawValue: task.providerID)
        )?.supportsSteer == true
      else {
        throw BridgeMCPQueryError.unavailable
      }
    }
    if task.providerID == serviceCodexProviderID {
      guard task.state.codexTurnID == expectedTurnID else {
        throw BridgeMCPQueryError.turnMismatch
      }
    } else {
      guard task.state.providerRunID == expectedTurnID else {
        throw BridgeMCPQueryError.turnMismatch
      }
    }
    do {
      try await coordinator.steer(
        taskID: id,
        expectedTurnID: expectedTurnID,
        text: input,
        interruptCurrentPrompt: mode == .interruptCurrentThenContinue
      )
    } catch {
      throw Self.publicExecutionError(error)
    }
    return MCPServiceTaskMutationReceipt(
      taskID: taskID,
      status: task.state.status.rawValue,
      accepted: true
    )
  }

  public func serviceInterruptTask(
    taskID: String,
    expectedTurnID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt {
    try Self.checkDeadline(deadline)
    let id = TaskID(rawValue: taskID)
    guard let task = try await tasks.task(id: id) else {
      throw BridgeMCPQueryError.taskNotFound
    }
    guard task.state.status == .running else {
      throw BridgeMCPQueryError.turnMismatch
    }
    if task.providerID != serviceCodexProviderID {
      guard let runID = task.state.providerRunID, runID == expectedTurnID else {
        throw BridgeMCPQueryError.turnMismatch
      }
      do {
        try await coordinator.interruptAgent(taskID: id, expectedRunID: expectedTurnID)
      } catch {
        throw Self.publicExecutionError(error)
      }
      return MCPServiceTaskMutationReceipt(
        taskID: taskID,
        status: task.state.status.rawValue,
        accepted: true
      )
    }
    guard task.state.codexTurnID == expectedTurnID else {
      throw BridgeMCPQueryError.turnMismatch
    }
    do {
      try await coordinator.interrupt(taskID: id, expectedTurnID: expectedTurnID)
    } catch {
      throw Self.publicExecutionError(error)
    }
    return MCPServiceTaskMutationReceipt(
      taskID: taskID,
      status: task.state.status.rawValue,
      accepted: true
    )
  }
}
