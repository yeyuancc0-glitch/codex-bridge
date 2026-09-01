#if os(Windows)
  import BridgeServiceAppCore
  import Foundation

  extension WindowsWorkspaceModel {
    func selectBlacklist(at index: Int) {
      guard blacklists.indices.contains(index) else { return }
      selectedBlacklistID = blacklists[index].id
      publishDisplay()
    }

    func saveBlacklist(executable: String, pattern: String) async {
      guard let projectID = selectedProjectID, let workspace = detail?.directWorkspace else {
        statusText = "当前项目没有可编辑的 Direct 工作区。"
        publishDisplay()
        return
      }
      let draft = BridgeBlacklistDraft(executable: executable, pattern: pattern)
      guard
        !draft.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        statusText = "黑名单的可执行文件或参数子串至少填写一项。"
        publishDisplay()
        return
      }
      guard connectionState == .connected, !busy else { return }
      busy = true
      statusText = "正在保存黑名单规则…"
      publishDisplay()
      defer { busy = false }
      var next = blacklists
      if let index = next.firstIndex(where: { $0.id == selectedBlacklistID }) {
        next[index] = draft
      } else {
        next.append(draft)
      }
      do {
        detail = try await client.updateProjectCommands(
          projectID: projectID,
          commands: commands.map { $0.toIPCCommand() },
          commandBlacklist: next.map { $0.toIPCRule() }
        )
        selectedBlacklistID = draft.id
        syncWorkspace()
        statusText = "黑名单规则已保存。"
      } catch {
        statusText = "黑名单保存失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func removeSelectedBlacklist() async {
      guard let selectedBlacklistID, let projectID = selectedProjectID,
        detail?.directWorkspace != nil, connectionState == .connected, !busy
      else { return }
      busy = true
      statusText = "正在移除黑名单规则…"
      publishDisplay()
      defer { busy = false }
      do {
        detail = try await client.updateProjectCommands(
          projectID: projectID,
          commands: commands.map { $0.toIPCCommand() },
          commandBlacklist:
            blacklists
            .filter { $0.id != selectedBlacklistID }
            .map { $0.toIPCRule() }
        )
        self.selectedBlacklistID = nil
        syncWorkspace()
        statusText = "黑名单规则已移除。"
      } catch {
        statusText = "移除黑名单失败：\(BridgeServiceErrorMessage.message(error))"
      }
      publishDisplay()
    }

    func reconcileBlacklistSelection() {
      if let selectedBlacklistID,
        blacklists.contains(where: { $0.id == selectedBlacklistID })
      {
        return
      }
      selectedBlacklistID = blacklists.first?.id
    }
  }
#endif
