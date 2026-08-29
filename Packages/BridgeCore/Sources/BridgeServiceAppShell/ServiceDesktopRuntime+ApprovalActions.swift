import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  public func resolveApproval(_ approval: IPCApprovalSummary, decision: String) {
    let resolutionKey = WorkbenchApprovalResolutionKey.task(approval.approvalID)
    guard resolvingApprovalKeys.insert(resolutionKey).inserted else { return }
    errorMessage = nil
    let providerName =
      tasks.first(where: { $0.taskID == approval.taskID })?.providerDisplayName
      ?? "Codex"
    Task { [weak self] in
      guard let self else { return }
      do {
        let client = try self.currentClient()
        try await client.resolveApproval(
          IPCApprovalResolutionRequest(
            taskID: approval.taskID,
            approvalID: approval.approvalID,
            decision: decision
          )
        )
        self.completeTaskApprovalResolution(
          approval,
          decision: decision,
          providerName: providerName
        )
        await self.refresh(silent: true, includeCatalog: false)
      } catch {
        let pending = try? await self.currentClient().approvals(taskID: approval.taskID)
        if let pending {
          self.applyApprovalSnapshot(pending)
        }
        if pending?.contains(where: { $0.approvalID == approval.approvalID }) != false {
          self.resolvingApprovalKeys.remove(resolutionKey)
          self.errorMessage = Self.message(error)
        } else {
          self.completeTaskApprovalResolution(
            approval,
            decision: decision,
            providerName: providerName
          )
        }
      }
    }
  }

  public func resolveDirectApproval(
    _ approval: IPCPendingDirectApproval,
    allow: Bool
  ) {
    let resolutionKey = WorkbenchApprovalResolutionKey.direct(approval.approvalID)
    guard resolvingApprovalKeys.insert(resolutionKey).inserted else { return }
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        let client = try self.currentClient()
        let accepted: Bool
        if allow {
          accepted = try await client.approveDirectApproval(approvalID: approval.approvalID)
        } else {
          accepted = try await client.denyDirectApproval(approvalID: approval.approvalID)
        }
        guard accepted else {
          self.resolvingApprovalKeys.remove(resolutionKey)
          self.errorMessage = "Direct 审批已失效或已被处理，请刷新状态。"
          return
        }
        self.completeDirectApprovalResolution(approval, allow: allow)
        await self.refresh(silent: true, includeCatalog: false)
      } catch {
        let pending = try? await self.currentClient().pendingDirectApprovals()
        if let pending {
          self.applyDirectApprovalSnapshot(pending)
        }
        if pending?.contains(where: { $0.approvalID == approval.approvalID }) != false {
          self.resolvingApprovalKeys.remove(resolutionKey)
          self.errorMessage = Self.message(error)
        } else {
          self.completeDirectApprovalResolution(approval, allow: allow)
        }
      }
    }
  }

  private func completeTaskApprovalResolution(
    _ approval: IPCApprovalSummary,
    decision: String,
    providerName: String
  ) {
    let resolutionKey = WorkbenchApprovalResolutionKey.task(approval.approvalID)
    resolvingApprovalKeys.remove(resolutionKey)
    resolvedTaskApprovalKeys.insert(resolutionKey)
    approvals.removeAll { $0.approvalID == approval.approvalID }
    postToast(
      decision == "deny" ? "已拒绝 \(providerName) 操作" : "已批准 \(providerName) 操作",
      symbol: decision == "deny" ? "xmark.shield.fill" : "checkmark.shield.fill",
      tone: decision == "deny" ? .warning : .success
    )
  }

  private func completeDirectApprovalResolution(
    _ approval: IPCPendingDirectApproval,
    allow: Bool
  ) {
    let resolutionKey = WorkbenchApprovalResolutionKey.direct(approval.approvalID)
    resolvingApprovalKeys.remove(resolutionKey)
    resolvedDirectApprovalKeys.insert(resolutionKey)
    directApprovals.removeAll { $0.approvalID == approval.approvalID }
    postToast(
      allow ? "已批准 Direct 操作" : "已拒绝 Direct 操作",
      symbol: allow ? "checkmark.shield.fill" : "xmark.shield.fill",
      tone: allow ? .success : .warning
    )
  }

  func isResolvingApproval(_ approval: IPCApprovalSummary) -> Bool {
    resolvingApprovalKeys.contains(WorkbenchApprovalResolutionKey.task(approval.approvalID))
  }

  func isResolvingDirectApproval(_ approval: IPCPendingDirectApproval) -> Bool {
    resolvingApprovalKeys.contains(WorkbenchApprovalResolutionKey.direct(approval.approvalID))
  }
}
