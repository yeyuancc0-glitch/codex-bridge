import BridgePresentation
import Foundation

enum FailClosedPresentationProjection {
  static func authorizedCapabilities(
    presentation: BridgePresentationSnapshot,
    sheet: PresentedBridgeSheet?,
    capabilities: [BridgeApprovalCapability]
  ) -> [BridgeApprovalCapability] {
    let approvalDetails = details(from: presentation.approvals)
    return capabilities.filter { capability in
      approvalDetails.contains { matches(capability, approval: $0) }
        || matches(capability, sheet: sheet)
    }
  }

  static func snapshot(
    _ snapshot: BridgePresentationSnapshot,
    capabilities: [BridgeApprovalCapability]
  ) -> BridgePresentationSnapshot {
    BridgePresentationSnapshot(
      overview: snapshot.overview,
      tasks: snapshot.tasks,
      projects: snapshot.projects,
      threads: snapshot.threads,
      approvals: approvalState(snapshot.approvals, capabilities: capabilities),
      connections: snapshot.connections,
      logs: snapshot.logs,
      settings: snapshot.settings
    )
  }

  static func sheet(
    _ sheet: PresentedBridgeSheet?,
    capabilities: [BridgeApprovalCapability]
  ) -> PresentedBridgeSheet? {
    guard case .codexApproval(let approval) = sheet else { return sheet }
    let eligible = eligibleCapability(
      for: approval,
      capabilities: capabilities
    )
    return .codexApproval(
      projectedApproval(approval, canAllow: eligible != nil)
    )
  }

  static func synchronizationFailure() -> BridgePresentationSnapshot {
    let error = PresentationErrorState(
      title: "状态同步已中断",
      message: "Bridge 无法确认当前本机状态。重新连接后再执行任何操作。"
    )
    return BridgePresentationSnapshot(
      overview: .failed(error),
      tasks: .failed(error),
      projects: .failed(error),
      threads: .failed(error),
      approvals: .failed(error),
      connections: .failed(error),
      logs: .failed(error),
      settings: .failed(error)
    )
  }

  private static func approvalState(
    _ state: PresentationLoadState<ApprovalPagePresentation>,
    capabilities: [BridgeApprovalCapability]
  ) -> PresentationLoadState<ApprovalPagePresentation> {
    guard case .ready(let page) = state else { return state }
    let details = page.details.map { detail in
      projectedApproval(
        detail,
        canAllow: eligibleCapability(for: detail, capabilities: capabilities) != nil
      )
    }
    return .ready(
      ApprovalPagePresentation(
        pending: page.pending,
        resolved: page.resolved,
        details: details
      )
    )
  }

  private static func eligibleCapability(
    for approval: CodexApprovalPresentation,
    capabilities: [BridgeApprovalCapability]
  ) -> BridgeApprovalCapability? {
    capabilities.first { capability in
      capability.allowOnceEligible && matches(capability, approval: approval)
    }
  }

  private static func details(
    from state: PresentationLoadState<ApprovalPagePresentation>
  ) -> [CodexApprovalPresentation] {
    guard case .ready(let page) = state else { return [] }
    return page.details
  }

  private static func matches(
    _ capability: BridgeApprovalCapability,
    sheet: PresentedBridgeSheet?
  ) -> Bool {
    guard case .codexApproval(let approval) = sheet else { return false }
    return matches(capability, approval: approval)
  }

  private static func matches(
    _ capability: BridgeApprovalCapability,
    approval: CodexApprovalPresentation
  ) -> Bool {
    approval.canAllow && capability.isComplete && capability.approvalID == approval.id
      && capability.taskID == approval.taskID
      && capability.threadID == approval.threadID
      && capability.turnID == approval.turnID
      && capability.operationID == approval.operationID
  }

  private static func projectedApproval(
    _ value: CodexApprovalPresentation,
    canAllow: Bool
  ) -> CodexApprovalPresentation {
    CodexApprovalPresentation(
      id: value.id,
      taskID: value.taskID,
      source: value.source,
      threadID: value.threadID,
      turnID: value.turnID,
      operationID: value.operationID,
      operationTitle: value.operationTitle,
      commandArguments: value.commandArguments,
      evidenceItems: value.evidenceItems,
      fileOperation: value.fileOperation,
      workingDirectory: value.workingDirectory,
      reason: value.reason,
      supervisorRisk: value.supervisorRisk,
      consequences: value.consequences,
      canAllow: value.canAllow && canAllow
    )
  }
}
