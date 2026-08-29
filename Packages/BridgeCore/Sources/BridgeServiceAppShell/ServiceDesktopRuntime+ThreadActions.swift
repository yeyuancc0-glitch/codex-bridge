import BridgeIPC
import BridgeMCP

extension BridgeServiceAppModel {
  public func openThread(_ threadID: String, inProject projectID: String? = nil) {
    openThread(threadID, inProject: projectID, preferredTaskID: nil)
  }

  private func openThread(
    _ threadID: String,
    inProject projectID: String?,
    preferredTaskID: String?
  ) {
    let targetProjectID =
      projectID ?? selectedProjectID
      ?? tasks.first(where: { $0.threadID == threadID })?.projectID
      ?? projects.first?.projectID
    guard let targetProjectID else { return }

    if selectedProjectID != targetProjectID {
      selectedProjectID = targetProjectID
      persistWorkbenchProjectSelection(targetProjectID)
    }
    selectedThreadID = threadID

    let relatedTask = tasks.first(where: {
      $0.threadID == threadID && $0.isCodexTask
        && (preferredTaskID == nil || $0.taskID == preferredTaskID)
    })
    selectedTaskID = relatedTask?.taskID

    if let preferredTaskID {
      openConversation(taskID: preferredTaskID)
    } else if let activeTask = tasks.first(where: {
      $0.threadID == threadID && $0.isCodexTask && $0.isRunning
    }) {
      openConversation(taskID: activeTask.taskID)
    } else {
      closeConversation()
    }

    runMutation { [weak self] client in
      guard let self else { return }
      let page = try await client.readThread(
        IPCThreadReadRequest(
          projectID: targetProjectID,
          threadID: threadID,
          detail: .full,
          limit: 100
        )
      )
      guard self.selectedThreadID == threadID else { return }
      self.selectedThread = page
    }
  }

  public func openTask(_ taskID: String) {
    guard let task = tasks.first(where: { $0.taskID == taskID }) else { return }

    if selectedProjectID != task.projectID {
      selectProject(task.projectID)
    }
    selectedTaskID = task.taskID
    selectedThread = nil
    selectedThreadID = task.isCodexTask ? task.threadID : nil

    if task.isCodexTask, let threadID = task.threadID {
      openThread(threadID, inProject: task.projectID, preferredTaskID: task.taskID)
    } else {
      openConversation(taskID: task.taskID)
    }
  }

  public func openConversation(taskID: String) {
    guard let client, connectionState == .connected else {
      errorMessage = "后台 Service 未连接，无法查看对话。"
      return
    }
    let task = tasks.first(where: { $0.taskID == taskID })
    if let task {
      selectedTaskID = task.taskID
      if task.isExternalAgentTask {
        selectedThread = nil
        selectedThreadID = nil
      }
    }
    closeConversation()
    let conversation = TaskConversationModel(
      taskID: taskID,
      client: client,
      isTerminal: task?.isTerminal == true
    )
    self.conversation = conversation
    Task {
      await conversation.start()
    }
  }

  public func closeConversation() {
    guard let conversation else { return }
    let taskID = conversation.taskID
    let subscriptionID = conversation.subscriptionID
    self.conversation = nil
    conversation.cancel()
    guard subscriptionID >= 0, let client, connectionState == .connected else { return }
    Task {
      try? await client.unsubscribeTaskConversation(
        taskID: taskID,
        subscriptionID: subscriptionID
      )
    }
  }
}
