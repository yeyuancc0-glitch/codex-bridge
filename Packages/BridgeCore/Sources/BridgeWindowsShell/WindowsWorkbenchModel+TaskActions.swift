#if os(Windows)
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    public func refreshSelectedTask() async {
      actionText = "正在刷新任务…"
      publishDisplay()
      await refreshTasks()
      guard connectionState == .connected else { return }
      actionText = "任务列表已刷新。"
      publishDisplay()
    }

    public func selectTask(at index: Int) {
      guard tasks.indices.contains(index) else { return }
      let task = tasks[index]
      guard selectedTaskID != task.taskID else {
        publishDisplay()
        return
      }
      if selectedProjectID != task.projectID {
        selectedProjectID = task.projectID
        threads = []
        Task {
          try? await client.setWorkbenchProject(projectID: task.projectID)
          await loadThreads()
        }
      }
      selectedTaskID = task.taskID
      selectedThreadID = task.isCodexTask ? task.threadID : nil
      selectedThreadPage = nil
      actionText = nil
      openConversation(for: task)
      publishDisplay()
    }

    public func stopSelectedTask() async {
      guard connectionState == .connected else {
        setActionText("后台 Service 未连接，无法停止任务。")
        return
      }
      guard let task = selectedTask, task.isActive else {
        setActionText("当前没有可停止的任务。")
        return
      }
      let requestTaskID = task.taskID
      actionText = "正在停止任务…"
      publishDisplay()
      do {
        try await client.stopTask(taskID: requestTaskID)
        await refreshTasks()
        guard shouldApplyActionResult(for: requestTaskID) else { return }
        setActionText("停止请求已发送。")
      } catch {
        let message = BridgeServiceErrorMessage.message(error)
        await loadTasks()
        guard shouldApplyActionResult(for: requestTaskID) else { return }
        setActionText("停止失败：\(message)")
      }
    }

    public func deleteSelectedTask() async {
      guard connectionState == .connected else {
        setActionText("后台 Service 未连接，无法删除任务。")
        return
      }
      guard let task = selectedTask, task.isTerminal else {
        setActionText("只能删除已结束的任务。")
        return
      }
      let requestTaskID = task.taskID
      actionText = "正在删除任务…"
      publishDisplay()
      do {
        try await client.deleteTask(taskID: requestTaskID)
        guard selectedTaskID == requestTaskID else { return }
        selectedTaskID = nil
        selectedThreadID = nil
        selectedThreadPage = nil
        conversation?.cancel()
        conversation = nil
        await refreshTasks()
        setActionText("任务已删除。")
      } catch {
        let message = BridgeServiceErrorMessage.message(error)
        await loadTasks()
        guard shouldApplyActionResult(for: requestTaskID) else { return }
        setActionText("删除失败：\(message)")
      }
    }

    public func interruptSelectedTask() async {
      guard connectionState == .connected else {
        setActionText("后台 Service 未连接，无法中断任务。")
        return
      }
      guard let task = selectedTask else {
        setActionText("请先选择要中断的任务。")
        return
      }
      guard let expectedTurnID = task.expectedControlID else {
        setActionText("当前任务不可中断。")
        return
      }
      let requestTaskID = task.taskID
      actionText = "正在发送中断请求…"
      publishDisplay()
      do {
        _ = try await client.interruptTask(
          taskID: requestTaskID,
          expectedTurnID: expectedTurnID
        )
        await refreshTasks()
        guard shouldApplyActionResult(for: requestTaskID) else { return }
        setActionText("中断请求已发送。")
      } catch {
        let message = BridgeServiceErrorMessage.message(error)
        await loadTasks()
        guard shouldApplyActionResult(for: requestTaskID) else { return }
        setActionText("中断失败：\(message)")
      }
    }

    public func submitSteer(input: String) async -> Bool {
      guard connectionState == .connected else {
        setActionText("后台 Service 未连接，无法发送 Steer。")
        return false
      }
      guard let task = selectedTask else {
        setActionText("请先选择要发送 Steer 的任务。")
        return false
      }
      guard
        TaskInspectorPresentation.canSteer(
          task,
          providerSupportsSteer: providerSupportsSteer(for: task)
        )
      else {
        setActionText("当前任务不支持 Steer。")
        return false
      }
      guard let validationMessage = TaskInspectorPresentation.steerValidationMessage(input)
      else {
        actionText = "正在发送 Steer…"
        publishDisplay()
        do {
          guard let expectedTurnID = task.expectedControlID else {
            setActionText("当前任务已不在可 Steer 状态。")
            return false
          }
          let requestTaskID = task.taskID
          _ = try await client.steerTask(
            taskID: requestTaskID,
            expectedTurnID: expectedTurnID,
            input: input,
            mode: .queued
          )
          await refreshTasks()
          guard shouldApplyActionResult(for: requestTaskID) else { return false }
          setActionText("Steer 已发送。")
          return true
        } catch {
          let message = BridgeServiceErrorMessage.message(error)
          await loadTasks()
          guard shouldApplyActionResult(for: task.taskID) else { return false }
          setActionText("Steer 发送失败：\(message)")
          return false
        }
      }
      setActionText(validationMessage)
      return false
    }

    private func setActionText(_ text: String) {
      actionText = text
      publishDisplay()
    }

    private func shouldApplyActionResult(for taskID: String) -> Bool {
      TaskInspectorPresentation.shouldApplyTaskActionResult(
        for: taskID,
        selectedTaskID: selectedTaskID
      )
    }
  }
#endif
