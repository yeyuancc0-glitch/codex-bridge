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
    permissionMode: String? = nil,
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
            permissionMode: permissionMode,
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
  func hydrateAgentModelState(installationID: String?) async {
    agentModelCatalogGeneration &+= 1
    let catalogGeneration = agentModelCatalogGeneration
    agentModelDefaultLoadGeneration &+= 1
    let defaultLoadGeneration = agentModelDefaultLoadGeneration

    if installationID == nil || installationID?.isEmpty == true {
      agentModelOptions = []
    }

    if let mutation = agentModelDefaultMutationTask {
      await mutation.value
    }
    guard !Task.isCancelled else { return }
    let defaultRevision = agentModelDefaultRevision
    guard let client = try? currentClient() else { return }

    async let defaultResponse = try? await client.agentModelDefault()
    let modelResponse: IPCAgentModelsResponse?
    if let installationID, !installationID.isEmpty {
      modelResponse = try? await client.agentModels(installationID: installationID)
    } else {
      modelResponse = nil
    }
    let persistedDefault = await defaultResponse

    guard !Task.isCancelled else { return }
    if catalogGeneration == agentModelCatalogGeneration, let modelResponse {
      agentModelOptions = modelResponse.models
    }
    guard defaultLoadGeneration == agentModelDefaultLoadGeneration,
      defaultRevision == agentModelDefaultRevision,
      let persistedDefault
    else { return }
    openCodeDefaultModel = persistedDefault.model
  }

  func saveAgentModelDefault(_ model: String?) {
    let previous = openCodeDefaultModel
    agentModelDefaultRevision &+= 1
    let revision = agentModelDefaultRevision
    openCodeDefaultModel = model
    let previousMutation = agentModelDefaultMutationTask
    let task = Task { [weak self, previousMutation] in
      await previousMutation?.value
      guard let self, !Task.isCancelled else { return }
      defer {
        if self.agentModelDefaultRevision == revision {
          self.agentModelDefaultMutationTask = nil
        }
      }
      do {
        let client = try self.currentClient()
        try await client.setAgentModelDefault(model)
        guard self.agentModelDefaultRevision == revision else { return }
        let persisted = try await client.agentModelDefault()
        guard self.agentModelDefaultRevision == revision else { return }
        self.openCodeDefaultModel = persisted.model
        self.postToast("OpenCode 默认模型已保存", symbol: "checkmark.circle.fill", tone: .success)
      } catch {
        guard self.agentModelDefaultRevision == revision else { return }
        self.openCodeDefaultModel = previous
        self.errorMessage = Self.message(error)
      }
    }
    agentModelDefaultMutationTask = task
  }
}
