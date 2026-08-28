import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceAppModel {
  public func stopTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.stopTask(taskID: taskID)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func interruptTask(_ task: MCPServiceTaskSnapshot) {
    guard let expectedTurnID = task.expectedControlID else { return }
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.interruptTask(
        taskID: task.taskID,
        expectedTurnID: expectedTurnID
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func steerTask(_ task: MCPServiceTaskSnapshot, input: String) {
    guard let expectedTurnID = task.expectedControlID,
      !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      input.utf8.count <= IPCTaskSteerRequest.maximumInputBytes,
      !input.contains("\0")
    else { return }
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.steerTask(
        taskID: task.taskID,
        expectedTurnID: expectedTurnID,
        input: input
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func deleteTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.deleteTask(taskID: taskID)
      if self.conversation?.taskID == taskID {
        self.closeConversation()
      }
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已删除任务记录")
    }
  }

  func loadThreads(projectID: String) async {
    do {
      let client = try currentClient()
      lastThreadCatalogRefreshAt = Date()
      let page = try await client.threads(
        IPCThreadListRequest(projectID: projectID, limit: 100)
      )
      guard selectedProjectID == projectID else { return }
      threads = page.threads
      reconcileThreadSelection()
    } catch {
      guard selectedProjectID == projectID else { return }
      threads = []
    }
  }
}
