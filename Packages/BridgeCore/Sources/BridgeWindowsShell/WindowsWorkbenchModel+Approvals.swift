#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    public func refreshApprovals() async {
      guard connectionState == .connected else {
        approvalStatusText = "后台 Service 未连接。"
        publishDisplay()
        return
      }
      guard !approvalRefreshInProgress else { return }
      approvalRefreshInProgress = true
      publishDisplay()

      var errors: [String] = []
      do {
        approvals = try await client.approvals(taskID: nil)
      } catch {
        errors.append("安全审批读取失败：\(BridgeServiceErrorMessage.message(error))")
      }
      do {
        directApprovals = try await client.pendingDirectApprovals()
      } catch {
        errors.append("Direct 审批读取失败：\(BridgeServiceErrorMessage.message(error))")
      }

      approvalRefreshInProgress = false
      reconcileApprovalSelection()
      approvalStatusText = errors.isEmpty ? nil : errors.joined(separator: "\r\n")
      publishDisplay()
    }

    public func selectApproval(at index: Int) {
      let items = approvalPresentationItems()
      guard items.indices.contains(index) else { return }
      let nextID = items[index].id
      guard selectedApprovalID != nextID else {
        publishDisplay()
        return
      }
      selectedApprovalID = nextID
      approvalSelectionGeneration &+= 1
      approvalStatusText = nil
      publishDisplay()
    }

    public func resolveSelectedApproval(decision: String) async {
      guard connectionState == .connected else {
        setApprovalStatus("后台 Service 未连接，无法处理审批。")
        return
      }
      guard let approvalID = selectedApprovalID,
        let item = approvalPresentationItems().first(where: { $0.id == approvalID })
      else {
        setApprovalStatus("请先选择要处理的审批。")
        return
      }
      guard decision == "deny" || item.allowDecisions.contains(decision) else {
        setApprovalStatus("当前审批不支持该决策。", for: approvalID)
        return
      }
      guard resolvingApprovalIDs.insert(approvalID).inserted else { return }
      let selectionGeneration = approvalSelectionGeneration
      approvalStatusText = "正在处理审批…"
      publishDisplay()

      do {
        try await sendApprovalDecision(approvalID, decision: decision)
        removeApproval(approvalID)
        await reloadTasksAndApprovals()
        finishApprovalResolution(
          approvalID,
          selectionGeneration: selectionGeneration,
          message: "已提交：\(ApprovalPresentation.decisionLabel(decision))。"
        )
      } catch {
        let message =
          error is WindowsApprovalError
          ? "审批已失效或已被处理，请刷新状态。"
          : "审批处理失败：\(BridgeServiceErrorMessage.message(error))"
        await reloadTasksAndApprovals()
        finishApprovalResolution(
          approvalID,
          selectionGeneration: selectionGeneration,
          message: message
        )
      }
    }

    private func sendApprovalDecision(
      _ approvalID: ApprovalPresentation.Identifier,
      decision: String
    ) async throws {
      switch approvalID {
      case .task(let rawID):
        guard let approval = approvals.first(where: { $0.approvalID == rawID }) else {
          throw WindowsApprovalError.noLongerAvailable
        }
        try await client.resolveApproval(
          IPCApprovalResolutionRequest(
            taskID: approval.taskID,
            approvalID: approval.approvalID,
            decision: decision
          )
        )
      case .direct(let rawID):
        let accepted: Bool
        if decision == "allow" {
          accepted = try await client.approveDirectApproval(approvalID: rawID)
        } else {
          accepted = try await client.denyDirectApproval(approvalID: rawID)
        }
        guard accepted else { throw WindowsApprovalError.noLongerAvailable }
      }
    }

    func approvalPresentationItems() -> [ApprovalPresentation.Item] {
      let taskItems = approvals.map { approval in
        ApprovalPresentation.task(
          approval,
          projectName: projectName(forTaskID: approval.taskID)
        )
      }
      let directItems = directApprovals.map { approval in
        ApprovalPresentation.direct(
          approval,
          projectName: projects.first(where: { $0.projectID == approval.projectID })?.name
        )
      }
      return taskItems + directItems
    }

    private func projectName(forTaskID taskID: String) -> String? {
      guard let projectID = tasks.first(where: { $0.taskID == taskID })?.projectID else {
        return nil
      }
      return projects.first(where: { $0.projectID == projectID })?.name
    }

    private func reloadTasksAndApprovals() async {
      await loadTasks()
      guard connectionState == .connected else { return }
      await refreshApprovals()
    }

    private func reconcileApprovalSelection() {
      guard let selectedApprovalID else { return }
      guard approvalPresentationItems().contains(where: { $0.id == selectedApprovalID }) else {
        self.selectedApprovalID = nil
        approvalStatusText = nil
      }
    }

    private func finishApprovalResolution(
      _ approvalID: ApprovalPresentation.Identifier,
      selectionGeneration: UInt64,
      message: String
    ) {
      resolvingApprovalIDs.remove(approvalID)
      guard approvalSelectionGeneration == selectionGeneration else {
        publishDisplay()
        return
      }
      approvalStatusText = message
      publishDisplay()
    }

    private func removeApproval(_ approvalID: ApprovalPresentation.Identifier) {
      switch approvalID {
      case .task(let rawID):
        approvals.removeAll { $0.approvalID == rawID }
      case .direct(let rawID):
        directApprovals.removeAll { $0.approvalID == rawID }
      }
    }

    private func setApprovalStatus(
      _ text: String,
      for approvalID: ApprovalPresentation.Identifier? = nil
    ) {
      guard approvalID == nil || selectedApprovalID == approvalID else { return }
      approvalStatusText = text
      publishDisplay()
    }
  }

  private enum WindowsApprovalError: Error {
    case noLongerAvailable
  }
#endif
