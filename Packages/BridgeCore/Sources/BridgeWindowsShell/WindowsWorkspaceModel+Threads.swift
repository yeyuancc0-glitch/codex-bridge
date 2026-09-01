#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsWorkspaceModel {
    func selectThread(at index: Int) {
      guard threads.indices.contains(index), let projectID = selectedProjectID else { return }
      let thread = threads[index]
      selectedThreadID = thread.threadID
      selectedThreadPage = nil
      statusText = "正在读取 Codex Thread…"
      publishDisplay()
      Task { await loadThread(thread.threadID, projectID: projectID) }
    }

    func reconcileThreadSelection() {
      if let selectedThreadID, threads.contains(where: { $0.threadID == selectedThreadID }) {
        return
      }
      selectedThreadID = threads.first?.threadID
      selectedThreadPage = nil
    }

    private func loadThread(_ threadID: String, projectID: String) async {
      do {
        let page = try await client.readThread(
          IPCThreadReadRequest(
            projectID: projectID,
            threadID: threadID,
            detail: .full
          )
        )
        guard selectedProjectID == projectID, selectedThreadID == threadID else { return }
        selectedThreadPage = page
        statusText = "Codex Thread 已加载。"
      } catch {
        guard selectedProjectID == projectID, selectedThreadID == threadID else { return }
        statusText = "Thread 读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }
  }
#endif
