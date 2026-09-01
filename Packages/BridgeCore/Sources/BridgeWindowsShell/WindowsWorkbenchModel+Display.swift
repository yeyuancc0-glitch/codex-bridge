#if os(Windows)
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    static let permissionModes = ["read-only", "workspace-write"]

    var visibleTasks: [MCPServiceTaskSnapshot] {
      tasks.filter { selectedProjectID == nil || $0.projectID == selectedProjectID }
    }

    var orphanThreads: [MCPThreadSummary] {
      let taskThreadIDs = Set(visibleTasks.compactMap { $0.isCodexTask ? $0.threadID : nil })
      return threads.filter { !taskThreadIDs.contains($0.threadID) }
    }

    func publishDisplay() {
      let runningCount = tasks.filter { $0.isRunning }.count
      let task = selectedTask
      let selectedTaskIndex = selectedTaskID.flatMap { selectedID in
        visibleTasks.firstIndex(where: { $0.taskID == selectedID })
      }
      let selectedThreadIndex = selectedThreadID.flatMap { selectedID in
        orphanThreads.firstIndex(where: { $0.threadID == selectedID })
      }
      let workbenchRows = visibleTasks.map(Self.rowText) + orphanThreads.map(Self.threadRowText)
      let selectedIndex =
        selectedTaskIndex
        ?? selectedThreadIndex.map { visibleTasks.count + $0 }
      let conversationText =
        selectedThreadPage.map(Self.threadConversationText)
        ?? TaskInspectorPresentation.conversationText(
          entries: conversation?.entries ?? [],
          isStreaming: conversation?.isStreaming == true || task?.isRunning == true,
          errorMessage: conversation?.errorMessage
        )
      let approvalItems = approvalPresentationItems()
      let selectedApprovalIndex = selectedApprovalID.flatMap { selectedID in
        approvalItems.firstIndex(where: { $0.id == selectedID })
      }
      let selectedApproval = selectedApprovalIndex.flatMap { approvalItems[$0] }
      let approvalResolving = selectedApprovalID.map(resolvingApprovalIDs.contains) ?? false
      let approvalActionsEnabled =
        connectionState == .connected
        && selectedApproval != nil
        && !approvalResolving
        && !approvalRefreshInProgress
      displayBox.store(
        WindowsWorkbenchDisplay(
          connectionState: connectionState,
          mcpAddress: serviceStatus?.localMCPURL ?? "—",
          taskCount: tasks.count,
          runningTaskCount: runningCount,
          pendingApprovalCount: approvalItems.count,
          projectRows: projects.map(\.name),
          selectedProjectIndex: selectedProjectID.flatMap { selectedID in
            projects.firstIndex(where: { $0.projectID == selectedID })
          },
          permissionRows: ["只读", "可写"],
          selectedPermissionIndex: Self.permissionModes.firstIndex(
            of: workbenchPermissionMode),
          taskRows: workbenchRows,
          recentTaskRows: tasks.map(Self.rowText),
          selectedTaskID: selectedTaskID,
          selectedTaskIndex: selectedIndex,
          taskMetadata: metadata(for: task),
          conversationText: conversationText,
          interruptEnabled: connectionState == .connected
            && TaskInspectorPresentation.canInterrupt(task),
          stopEnabled: connectionState == .connected && task?.isActive == true,
          deleteEnabled: connectionState == .connected && task?.isTerminal == true,
          steerEnabled: connectionState == .connected
            && TaskInspectorPresentation.canSteer(
              task,
              providerSupportsSteer: providerSupportsSteer(for: task)
            ),
          actionText: actionText,
          approvalRows: approvalItems.map(\.rowText),
          selectedApprovalIndex: selectedApprovalIndex,
          approvalDetailText: selectedApproval?.detailText ?? "暂无待处理审批。",
          approvalAllowDecisions: selectedApproval?.allowDecisions ?? [],
          approvalAllowEnabled: approvalActionsEnabled
            && !(selectedApproval?.allowDecisions.isEmpty ?? true),
          approvalDenyEnabled: approvalActionsEnabled,
          approvalStatusText: approvalStatusText,
          detailText: errorMessage
        )
      )
    }

    func providerSupportsSteer(for task: MCPServiceTaskSnapshot?) -> Bool {
      guard let task, !agentProviders.isEmpty else { return false }
      let providerID = task.providerIdentifier
      return agentProviders.contains {
        AgentProviderPresentation.identifier($0.providerID) == providerID && $0.supportsSteer
      }
    }

    private func metadata(for task: MCPServiceTaskSnapshot?) -> String {
      if let task {
        return TaskInspectorPresentation.metadata(
          for: task,
          projectName: projectName(for: task.projectID)
        )
      }
      if let thread = selectedThreadPage?.thread {
        return
          "Codex 历史会话\r\n\(thread.title ?? thread.preview ?? thread.threadID)\r\n状态：\(thread.status)"
      }
      return "未选择任务或会话"
    }

    private func projectName(for projectID: String) -> String {
      projects.first(where: { $0.projectID == projectID })?.name ?? projectID
    }

    private static func rowText(_ task: MCPServiceTaskSnapshot) -> String {
      let state = task.isRunning ? "运行中" : (task.isTerminal ? "已结束" : task.status)
      return "\(task.providerDisplayName) · \(task.workbenchTitle) — \(state)"
    }

    private static func threadRowText(_ thread: MCPThreadSummary) -> String {
      "Codex · \(thread.title ?? thread.preview ?? thread.threadID) — \(thread.status)"
    }

    private static func threadConversationText(_ page: MCPThreadReadPage) -> String {
      guard !page.entries.isEmpty else { return "此 Codex 会话暂无可显示记录。" }
      return page.entries.map { entry in
        let role = entry.role == "user" ? "用户" : (entry.role == "assistant" ? "Codex" : entry.role)
        return "\(role)：\(entry.text)"
      }.joined(separator: "\r\n\r\n")
    }
  }
#endif
