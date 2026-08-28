import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceTask(
    taskID: String,
    recentEventLimit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSnapshot {
    try Self.checkDeadline(deadline)
    let id = TaskID(rawValue: taskID)
    guard let task = try await tasks.task(id: id) else {
      throw BridgeMCPQueryError.taskNotFound
    }
    let eventLimit = min(max(recentEventLimit, 1), 6)
    let events = try await tasks.events(taskID: id, limit: eventLimit)
    let activityLimit = min(max(recentEventLimit, 1), 8)
    let activityMessages: [ServiceTaskMessageRecord]
    let recentActivityAvailable: Bool
    do {
      activityMessages = try await tasks.recentMessageActivity(taskID: id, limit: activityLimit)
      recentActivityAvailable = true
    } catch {
      activityMessages = []
      recentActivityAvailable = false
    }
    let recentActivity = activityMessages.enumerated().compactMap {
      taskActivity($0.element, sequence: Int64($0.offset + 1))
    }
    let isCodexProvider = task.providerID == serviceCodexProviderID
    let activityUpdatedAt =
      activityMessages
      .map(\.updatedAt)
      .max()
    let effectiveUpdatedAt = max(task.updatedAt, activityUpdatedAt ?? task.updatedAt)
    return MCPServiceTaskSnapshot(
      taskID: task.id.rawValue,
      projectID: task.projectID.rawValue,
      source: task.source.rawValue,
      sourceClientID: task.sourceClientID.isEmpty ? nil : task.sourceClientID,
      status: task.state.status.rawValue,
      providerID: task.providerID,
      installationID: task.installationID,
      executionModel: task.executionModel,
      executionEffort: task.executionEffort,
      threadID: isCodexProvider ? task.state.codexThreadID : nil,
      turnID: isCodexProvider ? task.state.codexTurnID : nil,
      providerSessionID: isCodexProvider ? nil : task.state.providerSessionID,
      providerRunID: isCodexProvider ? nil : task.state.providerRunID,
      permissionMode: task.permissionMode.rawValue,
      networkAccess: task.networkAllowed,
      currentStep: task.state.currentStep.map {
        Self.safe($0, maximum: 2 * 1_024)
      },
      changedFiles: Self.boundedChangedFiles(task.state.changedFiles),
      recentEvents: events.map {
        MCPServiceTaskEvent(
          sequence: $0.id,
          kind: $0.kind.rawValue,
          summary: Self.safe($0.summary, maximum: 1_024),
          occurredAt: iso8601.string(from: $0.createdAt)
        )
      },
      recentActivity: recentActivity,
      recentActivityAvailable: recentActivityAvailable,
      supervisorStatus: task.state.supervisorStatus.rawValue,
      supervisorSummary: task.state.supervisorSummary.map {
        Self.safe($0, maximum: 8 * 1_024)
      },
      localApprovalRequired: task.state.status == .awaitingLocalApproval
        || task.state.status == .waitingForCodexApproval,
      resultSummary: task.state.resultSummary.map {
        Self.safe($0, maximum: 32 * 1_024)
      },
      failureCode: task.state.failureCode,
      updatedAt: iso8601.string(from: effectiveUpdatedAt)
    )
  }

  private func taskActivity(
    _ message: ServiceTaskMessageRecord,
    sequence: Int64
  ) -> MCPServiceTaskActivity? {
    let kind: String
    let summary: String
    let toolName: String?
    let toolStatus: String?
    switch message.kind {
    case .user:
      return nil
    case .agent:
      kind = "text"
      summary = message.content
      toolName = nil
      toolStatus = nil
    case .reasoning:
      kind = "reasoning"
      summary = message.content
      toolName = nil
      toolStatus = nil
    case .toolCall:
      kind = "tool_lifecycle"
      let name = message.toolName ?? "tool"
      let status = message.toolStatus ?? "in_progress"
      summary = name + " (" + status + ")"
      toolName = message.toolName
      toolStatus = message.toolStatus
    }
    return MCPServiceTaskActivity(
      sequence: sequence,
      kind: kind,
      summary: Self.safe(summary, maximum: 768),
      occurredAt: iso8601.string(from: message.updatedAt),
      toolName: toolName.map { Self.safe($0, maximum: 256) },
      toolStatus: toolStatus.map { Self.safe($0, maximum: 64) }
    )
  }

  private static func boundedChangedFiles(_ paths: [String]) -> [String] {
    let maximumTotalBytes = 16 * 1_024
    var result: [String] = []
    var usedBytes = 0
    for path in paths {
      let safePath = safe(path, maximum: 2 * 1_024)
      let byteCount = safePath.utf8.count
      guard byteCount > 0, usedBytes + byteCount <= maximumTotalBytes else { break }
      result.append(safePath)
      usedBytes += byteCount
    }
    return result
  }
}
