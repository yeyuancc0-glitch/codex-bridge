import BridgeDirectCommand
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceStatus(
    deadline: ContinuousClock.Instant
  ) async throws -> BridgeStatusSnapshot {
    try Self.checkDeadline(deadline)
    let taskList = try await tasks.tasks(limit: 500)
    let runtime = await runtimeStatus.current()
    let codexApprovals = await coordinator.pendingApprovals().count
    let taskStartApprovals = taskList.filter {
      $0.state.status == .awaitingLocalApproval
        && $0.requiresLocalStartApproval
    }.count
    let directEnvironment = await directCommands.executionEnvironmentCapabilities()
    var degradations = runtime.degradations
    let activeTasks = taskList.filter { !$0.state.status.isTerminal }
    for task in activeTasks where task.state.supervisorStatus == .degraded {
      let summary =
        task.state.supervisorSummary
        ?? "Supervisor degraded for active task \(task.id.rawValue)"
      if !degradations.contains(summary) {
        degradations.append(summary)
      }
    }
    return BridgeStatusSnapshot(
      appVersion: appVersion,
      mcpState: runtime.mcpState,
      tunnelState: runtime.tunnelState,
      codexVersion: runtime.codexVersion,
      loginMode: runtime.loginMode,
      executionState: Self.executionState(taskList),
      supervisorState: Self.supervisorState(taskList),
      degradations: degradations,
      pendingApprovalCount: codexApprovals + taskStartApprovals,
      executionEnvironment: Self.mcpEnvironment(directEnvironment)
    )
  }
}
