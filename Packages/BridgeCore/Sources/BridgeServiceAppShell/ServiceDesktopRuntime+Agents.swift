import BridgeIPC
import Foundation

extension BridgeServiceAppModel {
  func registerAgentInstallation(
    providerID: String,
    displayName: String,
    executableURL: URL
  ) {
    runAgentMutation(
      operation: { client in
        try await client.registerAgentInstallation(
          IPCAgentRegistrationRequest(
            providerID: providerID,
            displayName: displayName,
            executablePath: executableURL.standardizedFileURL.path
          )
        )
      },
      successMessage: { installation in
        let name = installation?.displayName ?? displayName
        return installation?.availability == "available"
          ? "已登记并验证 \(name)，确认启用后才会进入可选目录"
          : "已登记 \(name)，但 Probe 尚未通过"
      }
    )
  }

  func reprobeAgentInstallation(
    _ installationID: String,
    acceptReplacement: Bool
  ) {
    runAgentMutation(
      operation: { client in
        try await client.reprobeAgentInstallation(
          installationID: installationID,
          acceptReplacement: acceptReplacement
        )
      },
      successMessage: { installation in
        installation?.availability == "available"
          ? "Agent Probe 已通过"
          : "Agent Probe 未通过，请查看安装状态"
      }
    )
  }

  func setAgentInstallationEnabled(_ installationID: String, enabled: Bool) {
    runAgentMutation(
      operation: { client in
        try await client.setAgentInstallationEnabled(
          installationID: installationID,
          enabled: enabled
        )
      },
      successMessage: { installation in
        installation?.isEnabled == true ? "Agent 安装已启用" : "Agent 安装已停用"
      }
    )
  }

  func removeAgentInstallation(_ installationID: String) {
    runAgentMutation(
      operation: { client in
        try await client.removeAgentInstallation(installationID: installationID)
        return nil
      },
      successMessage: { _ in "已移除 Agent 安装登记" }
    )
  }

  private func runAgentMutation(
    operation:
      @escaping @MainActor @Sendable (any BridgeServiceClientProtocol) async throws
      -> IPCAgentInstallationSummary?,
    successMessage: @escaping @MainActor @Sendable (IPCAgentInstallationSummary?) -> String
  ) {
    guard !isManagingAgents else { return }
    isManagingAgents = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      defer { self.isManagingAgents = false }
      do {
        let client = try self.currentClient()
        let installation = try await operation(client)
        let catalog = try await client.agentCatalog()
        self.agentProviders = catalog.providers
        self.agentInstallations = catalog.installations
        let isSuccess = installation?.availability == "available" || installation == nil
        self.postToast(
          successMessage(installation),
          symbol: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
          tone: isSuccess ? .success : .warning
        )
      } catch {
        self.errorMessage = Self.message(error)
      }
    }
  }
}

extension BridgeServiceAppModel {
  func submitAgentTask(
    projectID: String,
    providerID: String,
    installationID: String?,
    model: String?,
    prompt: String
  ) {
    guard !isManagingAgents else { return }
    isManagingAgents = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      defer { self.isManagingAgents = false }
      do {
        let client = try self.currentClient()
        let response = try await client.submitAgentTask(
          IPCAgentSubmitRequest(
            projectID: projectID,
            providerID: providerID,
            installationID: installationID,
            model: (model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
              $0.isEmpty ? nil : $0
            },
            prompt: prompt
          )
        )
        self.postToast(
          response.status == "awaiting_local_approval"
            ? "任务已提交，请在工作台批准后执行"
            : "任务状态：\(response.status)",
          symbol: "paperplane.fill",
          tone: .success
        )
      } catch {
        self.errorMessage = Self.message(error)
      }
    }
  }
}

extension BridgeServiceAppModel {
  func loadAgentModels(installationID: String?) {
    guard let installationID, !installationID.isEmpty else {
      agentModelOptions = []
      return
    }
    Task { [weak self] in
      guard let self, let client = try? self.currentClient() else { return }
      let response = try? await client.agentModels(installationID: installationID)
      await MainActor.run {
        self.agentModelOptions = response?.models ?? []
      }
    }
  }
}

extension BridgeServiceAppModel {
  func loadAgentModelDefault() {
    Task { [weak self] in
      guard let self, let client = try? self.currentClient() else { return }
      let response = try? await client.agentModelDefault()
      await MainActor.run { self.openCodeDefaultModel = response?.model }
    }
  }

  func saveAgentModelDefault(_ model: String?) {
    Task { [weak self] in
      guard let self, let client = try? self.currentClient() else { return }
      do {
        try await client.setAgentModelDefault(model)
        await MainActor.run {
          self.openCodeDefaultModel = model
          self.postToast("OpenCode 默认模型已保存", symbol: "checkmark.circle.fill", tone: .success)
        }
      } catch {
        await MainActor.run { self.errorMessage = Self.message(error) }
      }
    }
  }
}
