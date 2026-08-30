import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import BridgeSupervisor
import Foundation

extension ServiceExecutionCoordinator {
  public func pendingApprovals(taskID: TaskID? = nil) async -> [ExecutionApprovalRequest] {
    let expired = purgeExpiredAgentApprovals()
    for approval in expired {
      await failExpiredAgentApproval(approval)
    }
    let codex = await execution.pendingApprovals(taskID: taskID)
    let agents = pendingAgentApprovals.values
      .filter { taskID == nil || $0.request.taskID == taskID }
      .compactMap { try? executionApproval(from: $0.request) }
    return (codex + agents).sorted { lhs, rhs in
      if lhs.taskID.rawValue == rhs.taskID.rawValue {
        return lhs.id < rhs.id
      }
      return lhs.taskID.rawValue < rhs.taskID.rawValue
    }
  }
  public func resolveApproval(
    taskID: TaskID,
    approvalID: String,
    decision: LocalApprovalDecision
  ) async throws {
    if let pending = pendingAgentApprovals[approvalID] {
      guard pending.request.taskID == taskID else {
        throw ExecutionServiceError.bindingMismatch
      }
      try await resolveAgentApproval(pending, taskID: taskID, decision: decision)
      return
    }
    try await execution.respondToApproval(
      taskID: taskID,
      approvalID: approvalID,
      decision: decision
    )
    do {
      let updated = try await tasks.resumeAfterCodexApproval(
        taskID: taskID,
        approved: decision.isApproval
      )
      await execution.finalizeApproval(
        taskID: taskID,
        approvalID: approvalID,
        committed: true
      )
      await supervision.observe(
        task: updated,
        kind: .progress,
        summary: decision == .allow
          ? "The local user approved a Codex operation."
          : "The local user denied a Codex operation; Codex may choose a safer path."
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
  private func resolveAgentApproval(
    _ pending: PendingAgentApproval,
    taskID: TaskID,
    decision: LocalApprovalDecision
  ) async throws {
    let approval = pending.request
    guard Date().timeIntervalSince(pending.createdAt) <= agentApprovalLifetime else {
      pendingAgentApprovals.removeValue(forKey: approval.approvalID)
      await failExpiredAgentApproval(pending)
      throw ExecutionServiceError.approvalUnavailable(approval.approvalID)
    }
    guard let run = activeAgentRuns[taskID],
      run.providerID == approval.binding.providerID.rawValue,
      run.installationID == approval.binding.installationID.rawValue,
      run.providerSessionID == approval.binding.providerSessionID,
      run.providerRunID == approval.binding.providerRunID,
      let resolveApproval = run.resolveApproval
    else {
      pendingAgentApprovals.removeValue(forKey: approval.approvalID)
      await failAgentApproval(
        taskID: taskID,
        code: "agent_approval_binding_mismatch",
        summary: "The agent approval binding no longer matches the active run."
      )
      throw ExecutionServiceError.bindingMismatch
    }
    guard
      let optionID = Self.agentApprovalOptionID(
        for: decision,
        options: approval.options
      )
    else {
      throw ExecutionServiceError.approvalUnavailable(approval.approvalID)
    }

    pendingAgentApprovals.removeValue(forKey: approval.approvalID)
    do {
      let updated = try await tasks.resumeAfterCodexApproval(
        taskID: taskID,
        approved: decision.isApproval
      )
      await supervision.observe(
        task: updated,
        kind: .progress,
        summary: decision.isApproval
          ? "The local user approved an agent operation."
          : "The local user denied an agent operation."
      )
    } catch {
      await failAgentApproval(
        taskID: taskID,
        code: "agent_approval_state_failed",
        summary: "The agent approval state could not be persisted."
      )
      throw error
    }
    do {
      try await resolveApproval(approval.approvalID, optionID)
    } catch {
      await failAgentApproval(
        taskID: taskID,
        code: "agent_approval_response_failed",
        summary: "The agent approval response could not be delivered."
      )
      throw ExecutionServiceError.processUnavailable
    }
  }
  private func failAgentApproval(taskID: TaskID, code: String, summary: String) async {
    guard !finishedRuns.contains(taskID) else { return }
    finishedRuns.insert(taskID)
    pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
    if let run = activeAgentRuns.removeValue(forKey: taskID) {
      await run.shutdown()
    }
    _ = await conversation.close(taskID: taskID)
    _ = try? await tasks.fail(taskID: taskID, failureCode: code, summary: summary)
  }
  private func failExpiredAgentApproval(_ pending: PendingAgentApproval) async {
    await failAgentApproval(
      taskID: pending.request.taskID,
      code: "agent_approval_expired",
      summary: "The agent approval expired before a local decision was made."
    )
  }
  private func purgeExpiredAgentApprovals() -> [PendingAgentApproval] {
    let now = Date()
    let expired = pendingAgentApprovals.values.filter {
      now.timeIntervalSince($0.createdAt) > agentApprovalLifetime
    }
    for approval in expired {
      pendingAgentApprovals.removeValue(forKey: approval.request.approvalID)
    }
    return expired
  }
  func registerAgentApproval(
    _ approval: AgentApprovalRequest,
    taskID: TaskID
  ) async throws -> ServiceTaskRecord {
    guard approval.taskID == taskID,
      let run = activeAgentRuns[taskID],
      run.providerID == approval.binding.providerID.rawValue,
      run.installationID == approval.binding.installationID.rawValue,
      run.providerSessionID == approval.binding.providerSessionID,
      run.providerRunID == approval.binding.providerRunID,
      run.resolveApproval != nil
    else {
      throw ExecutionServiceError.bindingMismatch
    }
    guard pendingAgentApprovals[approval.approvalID] == nil else {
      throw AgentRuntimeError.malformedEvent("agent.approval.duplicate")
    }
    _ = try executionApproval(from: approval)
    let updated = try await tasks.markWaitingForCodexApproval(taskID: taskID)
    guard !finishedRuns.contains(taskID),
      activeAgentRuns[taskID]?.effectiveRunID == run.effectiveRunID
    else {
      throw AgentRuntimeError.runMismatch
    }
    pendingAgentApprovals[approval.approvalID] = PendingAgentApproval(
      request: approval,
      createdAt: Date()
    )
    return updated
  }
  private func executionApproval(
    from approval: AgentApprovalRequest
  ) throws -> ExecutionApprovalRequest {
    let sessionID = approval.binding.providerSessionID ?? approval.taskID.rawValue
    let runID = approval.binding.providerRunID ?? approval.approvalID
    let binding = try ExecutionBinding(
      threadID: "agent:\(sessionID)",
      turnID: "agent:\(runID)"
    )
    let title = String(decoding: approval.title.utf8.prefix(512), as: UTF8.self)
    let providerName = providerDisplayNameResolver(approval.binding.providerID)
    let summary: String
    if let command = approval.normalizedCommand, !command.isEmpty {
      summary = String(
        decoding: "\(providerName) requested permission for: \(command)".utf8.prefix(4 * 1_024),
        as: UTF8.self
      )
    } else if let target = approval.networkTarget, !target.isEmpty {
      summary = String(
        decoding: "\(providerName) requested network permission for: \(target)".utf8.prefix(
          4 * 1_024),
        as: UTF8.self
      )
    } else {
      summary = String(decoding: approval.title.utf8.prefix(4 * 1_024), as: UTF8.self)
    }
    let availableDecisions = try Self.agentApprovalDecisions(options: approval.options)
    return try ExecutionApprovalRequest(
      id: approval.approvalID,
      taskID: approval.taskID,
      binding: binding,
      itemID: approval.providerItemID,
      kind: Self.executionApprovalKind(approval.kind),
      title: title,
      summary: summary,
      displayCommand: approval.normalizedCommand,
      relativePaths: approval.relativePaths,
      reason: approval.networkTarget.map { "Network target: \($0)" },
      availableDecisions: availableDecisions
    )
  }
  private static func executionApprovalKind(_ kind: AgentApprovalKind)
    -> ExecutionApprovalKind
  {
    switch kind {
    case .command:
      .command
    case .fileChange:
      .fileChange
    case .network, .tool, .unknown:
      .permissions
    }
  }

  private static func agentApprovalDecisions(
    options: [AgentApprovalOption]
  ) throws -> [LocalApprovalDecision] {
    var decisions: [LocalApprovalDecision] = []
    if options.contains(where: isAllowOnce) {
      decisions.append(.allow)
    }
    if options.contains(where: isAllowForSession) {
      decisions.append(.allowForSession)
    }
    guard options.contains(where: isDeny) else {
      throw ExecutionServiceError.invalidRequest("approval.options")
    }
    decisions.append(.deny)
    return decisions
  }

  private static func agentApprovalOptionID(
    for decision: LocalApprovalDecision,
    options: [AgentApprovalOption]
  ) -> String? {
    switch decision {
    case .allow:
      options.first(where: isAllowOnce)?.id
    case .allowForSession:
      options.first(where: isAllowForSession)?.id
    case .deny:
      options.first(where: isDeny)?.id
    case .allowSimilarCommands:
      nil
    }
  }

  private static func normalizedApprovalKind(_ option: AgentApprovalOption) -> String {
    option.kind
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: " ", with: "_")
  }

  private static func isAllowOnce(_ option: AgentApprovalOption) -> Bool {
    ["allow_once", "approve_once", "allow"].contains(normalizedApprovalKind(option))
  }

  private static func isAllowForSession(_ option: AgentApprovalOption) -> Bool {
    [
      "allow_always", "approve_always", "allow_for_session", "approve_for_session",
    ].contains(normalizedApprovalKind(option))
  }

  private static func isDeny(_ option: AgentApprovalOption) -> Bool {
    ["reject_once", "reject_always", "deny"].contains(normalizedApprovalKind(option))
  }
}
