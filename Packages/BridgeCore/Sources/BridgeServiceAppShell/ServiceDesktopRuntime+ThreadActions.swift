import BridgeIPC
import BridgeMCP

extension BridgeServiceAppModel {
  public func openThread(_ threadID: String, inProject projectID: String? = nil) {
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

    let relatedTask =
      tasks
      .filter {
        $0.projectID == targetProjectID && $0.threadID == threadID && $0.isCodexTask
      }
      .max { $0.updatedAt < $1.updatedAt }
    if let relatedTask {
      selectedTaskID = relatedTask.taskID
      selectedThread = nil
      openConversation(taskID: relatedTask.taskID)
      return
    }

    selectedTaskID = nil
    closeConversation()

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
      guard self.selectedThreadID == threadID, self.selectedTaskID == nil else { return }
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

    openConversation(taskID: task.taskID)
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
    conversation.restorePresentation(conversationPresentationCache.snapshot(for: taskID))
    self.conversation = conversation
    Task {
      await conversation.start()
    }
  }

  public func closeConversation() {
    guard let conversation else { return }
    conversationPresentationCache.store(
      conversation.presentationSnapshot(),
      for: conversation.taskID
    )
    self.conversation = nil
    conversation.cancel()
  }
}
