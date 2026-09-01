#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func loadThreads() async {
      guard connectionState == .connected, let projectID = selectedProjectID else {
        threads = []
        selectedThreadID = nil
        selectedThreadPage = nil
        publishDisplay()
        return
      }
      do {
        let page = try await client.threads(IPCThreadListRequest(projectID: projectID))
        guard selectedProjectID == projectID else { return }
        threads = page.threads
        if let selectedThreadID,
          !threads.contains(where: { $0.threadID == selectedThreadID })
        {
          self.selectedThreadID = nil
          selectedThreadPage = nil
        }
        publishDisplay()
      } catch {
        guard selectedProjectID == projectID else { return }
        threads = []
        actionText = "读取 Codex 历史会话失败：\(BridgeServiceErrorMessage.message(error))"
        publishDisplay()
      }
    }

    func selectDefaultTaskIfNeeded() {
      guard selectedTaskID == nil, selectedThreadID == nil else { return }
      guard let task = visibleTasks.first(where: { $0.isActive }) ?? visibleTasks.first else {
        return
      }
      selectedTaskID = task.taskID
      selectedThreadID = task.isCodexTask ? task.threadID : nil
      selectedThreadPage = nil
      openConversation(for: task)
    }

    public func selectWorkbenchProject(at index: Int) async {
      guard projects.indices.contains(index) else { return }
      let projectID = projects[index].projectID
      guard projectID != selectedProjectID else { return }

      selectedProjectID = projectID
      clearWorkbenchSelection()
      threads = []
      actionText = "正在切换项目…"
      publishDisplay()
      do {
        try await client.setWorkbenchProject(projectID: projectID)
        await loadThreads()
        await loadTasks()
        guard selectedProjectID == projectID else { return }
        actionText = "工作台项目已切换。"
        publishDisplay()
      } catch {
        actionText = "切换项目失败：\(BridgeServiceErrorMessage.message(error))"
        publishDisplay()
      }
    }

    public func selectWorkbenchPermission(at index: Int) async {
      guard Self.permissionModes.indices.contains(index) else { return }
      let mode = Self.permissionModes[index]
      guard mode != workbenchPermissionMode else { return }
      let previous = workbenchPermissionMode
      workbenchPermissionMode = mode
      actionText = "正在保存权限模式…"
      publishDisplay()
      do {
        try await client.setWorkbenchPermissionMode(mode)
        actionText = "工作台权限模式已保存。"
      } catch {
        workbenchPermissionMode = previous
        actionText = "保存权限模式失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    public func selectWorkbenchItem(at index: Int) async {
      if visibleTasks.indices.contains(index) {
        selectTask(visibleTasks[index])
        return
      }
      let threadIndex = index - visibleTasks.count
      guard orphanThreads.indices.contains(threadIndex) else { return }
      await openThread(orphanThreads[threadIndex])
    }

    private func selectTask(_ task: MCPServiceTaskSnapshot) {
      selectedTaskID = task.taskID
      selectedThreadID = task.isCodexTask ? task.threadID : nil
      selectedThreadPage = nil
      actionText = nil
      openConversation(for: task)
      publishDisplay()
    }

    private func openThread(_ thread: MCPThreadSummary) async {
      guard let projectID = selectedProjectID else { return }
      if let task =
        visibleTasks
        .filter({ $0.isCodexTask && $0.threadID == thread.threadID })
        .max(by: { $0.updatedAt < $1.updatedAt })
      {
        selectTask(task)
        return
      }

      selectedTaskID = nil
      selectedThreadID = thread.threadID
      selectedThreadPage = nil
      conversation?.cancel()
      conversation = nil
      actionText = "正在读取 Codex 历史会话…"
      publishDisplay()
      do {
        let page = try await client.readThread(
          IPCThreadReadRequest(
            projectID: projectID,
            threadID: thread.threadID,
            detail: .full
          )
        )
        guard selectedProjectID == projectID, selectedThreadID == thread.threadID else {
          return
        }
        selectedThreadPage = page
        actionText = nil
      } catch {
        guard selectedProjectID == projectID, selectedThreadID == thread.threadID else {
          return
        }
        actionText = "读取会话失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    private func clearWorkbenchSelection() {
      selectedTaskID = nil
      selectedThreadID = nil
      selectedThreadPage = nil
      conversation?.cancel()
      conversation = nil
      conversationWasTerminal = false
    }
  }
#endif
