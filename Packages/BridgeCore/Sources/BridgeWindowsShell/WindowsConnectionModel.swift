#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  @MainActor
  final class WindowsConnectionModel {
    static let exposureModes: [MCPServiceExposureMode] = [.readOnly, .full]

    let client: any BridgeServiceClientProtocol
    let displayBox: AuxiliaryDisplayBox<WindowsConnectionDisplay>
    var connectionState = WindowsWorkbenchDisplay.ConnectionState.idle
    var serviceStatus: IPCServiceStatusResponse?
    var clients: [IPCMCPClientStatus] = []
    var selectedClientID: String?
    var busy = false
    var statusText = "尚未读取 MCP 客户端状态。"

    init(client: any BridgeServiceClientProtocol) {
      self.client = client
      displayBox = AuxiliaryDisplayBox(value: Self.emptyDisplay)
    }

    func refresh() async {
      guard !busy else { return }
      busy = true
      statusText = "正在读取 MCP 客户端状态…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        async let statusRequest = client.status()
        async let clientsRequest = client.mcpClients()
        serviceStatus = try await statusRequest
        clients = try await clientsRequest
        connectionState = .connected
        reconcileSelection()
        statusText = "MCP 客户端状态已刷新。"
      } catch {
        connectionState = .unavailable
        statusText = "MCP 状态读取失败：\(BridgeServiceErrorMessage.message(error))"
      }
    }

    func selectClient(at index: Int) {
      guard clients.indices.contains(index) else { return }
      selectedClientID = clients[index].clientID
      publishDisplay()
    }

    func toggleSelectedClient() async {
      guard let profile = selectedClient, profile.clientID == MCPClientID.qwenStudio.rawValue else {
        return
      }
      await mutate("正在更新 Qwen Studio 状态…") {
        try await self.client.setMCPClientEnabled(
          clientID: profile.clientID,
          enabled: !profile.enabled
        )
      }
    }

    func setSelectedExposure(at index: Int) async {
      guard Self.exposureModes.indices.contains(index), let profile = selectedClient else { return }
      let mode = Self.exposureModes[index]
      await mutate("正在保存工具权限…") {
        if profile.clientID == MCPClientID.chatGPT.rawValue {
          try await self.client.setExposureMode(mode)
        } else {
          try await self.client.setMCPClientExposureMode(clientID: profile.clientID, mode: mode)
        }
      }
    }

    func exportSelectedConfiguration() async -> String? {
      guard let profile = selectedClient, profile.clientID == MCPClientID.qwenStudio.rawValue,
        profile.enabled
      else { return nil }
      do {
        let value = try await client.exportMCPClientConfiguration(clientID: profile.clientID)
        statusText = "Qwen JSON 配置已生成。"
        publishDisplay()
        return value
      } catch {
        statusText = "生成 Qwen 配置失败：\(BridgeServiceErrorMessage.message(error))"
        publishDisplay()
        return nil
      }
    }

    func rotateSelectedCredential() async {
      guard let profile = selectedClient, profile.clientID == MCPClientID.qwenStudio.rawValue,
        profile.enabled
      else { return }
      await mutate("正在重新生成 Qwen 凭证…") {
        try await self.client.rotateMCPClientCredential(clientID: profile.clientID)
      }
    }

    func rotateEndpoint() async {
      await mutate("正在重新生成本地 MCP Endpoint…") {
        _ = try await self.client.rotateLocalMCPEndpoint()
      }
    }

    func didCopyConfiguration(_ success: Bool) {
      statusText = success ? "已复制 Qwen Studio JSON 配置。" : "复制 Qwen 配置失败。"
      publishDisplay()
    }

    func refreshDisplaySnapshot() { publishDisplay() }

    private func mutate(_ progress: String, action: () async throws -> Void) async {
      guard connectionState == .connected, !busy else { return }
      busy = true
      statusText = progress
      publishDisplay()
      do {
        try await action()
        busy = false
        await refresh()
      } catch {
        busy = false
        statusText = "操作失败：\(BridgeServiceErrorMessage.message(error))"
        publishDisplay()
      }
    }

    private var selectedClient: IPCMCPClientStatus? {
      guard let selectedClientID else { return nil }
      return clients.first { $0.clientID == selectedClientID }
    }

    private func reconcileSelection() {
      if let selectedClientID, clients.contains(where: { $0.clientID == selectedClientID }) {
        return
      }
      selectedClientID = clients.first?.clientID
    }

    private func publishDisplay() {
      let profile = selectedClient
      let selectedIndex = selectedClientID.flatMap { id in
        clients.firstIndex { $0.clientID == id }
      }
      let isQwen = profile?.clientID == MCPClientID.qwenStudio.rawValue
      let enabled = profile?.enabled == true
      displayBox.store(
        WindowsConnectionDisplay(
          connectionState: connectionState,
          clientRows: clients.map {
            "\($0.displayName) — \($0.enabled ? "已启用" : "已停用") · Session \($0.activeSessionCount)"
          },
          selectedClientIndex: selectedIndex,
          clientDetailText: detailText(profile),
          endpointText: serviceStatus?.localMCPURL ?? "本地 MCP Endpoint 暂不可用",
          exposureRows: ["只读", "完整"],
          selectedExposureIndex: profile.flatMap {
            Self.exposureModes.firstIndex(of: $0.exposureMode)
          },
          toggleTitle: isQwen
            ? (enabled ? "停用 Qwen Studio" : "启用 Qwen Studio")
            : "ChatGPT 保持启用",
          toggleEnabled: isQwen && !busy,
          saveExposureEnabled: enabled && !busy,
          copyConfigurationEnabled: isQwen && enabled && !busy,
          rotateCredentialEnabled: isQwen && enabled && !busy,
          rotateEndpointEnabled: connectionState == .connected && !busy,
          statusText: statusText
        )
      )
    }

    private func detailText(_ profile: IPCMCPClientStatus?) -> String {
      guard let profile else { return "请选择 MCP 客户端。" }
      let permission = profile.exposureMode == .full ? "完整" : "只读"
      return [
        "客户端：\(profile.displayName)",
        "状态：\(profile.enabled ? "已启用" : "已停用")",
        "工具权限：\(permission)",
        "活动 Session：\(profile.activeSessionCount)",
        "最近连接：\(profile.lastConnectedAt ?? "无")",
        "",
        profile.exposureMode == .full
          ? "暴露任务与 Direct 工具；项目权限、workspace gate 与本机审批仍然生效。"
          : "仅暴露项目、文件、任务、Thread、模型与 Skill 查询工具。",
        "",
        "Secure Tunnel 在 Windows 版不可用；本地 MCP 与 Qwen Studio 不受影响。",
      ].joined(separator: "\r\n")
    }

    private static let emptyDisplay = WindowsConnectionDisplay(
      connectionState: .idle,
      clientRows: [],
      selectedClientIndex: nil,
      clientDetailText: "请选择 MCP 客户端。",
      endpointText: "—",
      exposureRows: ["只读", "完整"],
      selectedExposureIndex: nil,
      toggleTitle: "启用 Qwen Studio",
      toggleEnabled: false,
      saveExposureEnabled: false,
      copyConfigurationEnabled: false,
      rotateCredentialEnabled: false,
      rotateEndpointEnabled: false,
      statusText: "尚未读取 MCP 客户端状态。"
    )
  }
#endif
