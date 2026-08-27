import BridgeIPC
import Foundation

extension BridgeServiceAppModel {
  func refreshAgentModelCatalog(
    installationID: String?,
    providerID: String = "opencode"
  ) {
    guard !isRefreshingAgentModels else { return }
    guard let installationID, !installationID.isEmpty else {
      agentModelRefreshError = "暂无已启用且可用的 \(agentProviderName(providerID)) 安装。"
      return
    }

    agentModelCatalogGeneration &+= 1
    let catalogGeneration = agentModelCatalogGeneration
    agentModelRefreshGeneration &+= 1
    let refreshGeneration = agentModelRefreshGeneration
    agentModelDefaultLoadGeneration &+= 1
    let previousMutation = agentModelDefaultMutationTask
    isRefreshingAgentModels = true
    agentModelRefreshError = nil

    Task { [weak self, previousMutation] in
      guard let self else { return }
      defer {
        if self.agentModelRefreshGeneration == refreshGeneration {
          self.isRefreshingAgentModels = false
        }
      }

      do {
        await previousMutation?.value
        guard !Task.isCancelled,
          catalogGeneration == self.agentModelCatalogGeneration
        else { return }
        let defaultRevision = self.agentModelDefaultRevision
        let client = try self.currentClient()
        let persistedDefault = try await client.agentModelDefault(providerID: providerID)
        guard !Task.isCancelled,
          defaultRevision == self.agentModelDefaultRevision
        else { return }
        let defaultModel = persistedDefault.model
        let rawResponse = try await client.agentModels(
          installationID: installationID,
          projectID: self.selectedProjectID,
          modelID: nil,
          useStoredDefault: false
        )
        guard !Task.isCancelled,
          catalogGeneration == self.agentModelCatalogGeneration,
          refreshGeneration == self.agentModelRefreshGeneration,
          defaultRevision == self.agentModelDefaultRevision
        else { return }

        let previousIDs = Set(self.agentModelOptions.map(\.modelID))
        let currentIDs = Set(rawResponse.models.map(\.modelID))
        let addedCount = currentIDs.subtracting(previousIDs).count
        let removedCount = previousIDs.subtracting(currentIDs).count
        let defaultWasRemoved = defaultModel.map { !currentIDs.contains($0) } ?? false
        let response: IPCAgentModelsResponse
        if let defaultModel, !defaultWasRemoved {
          response = try await client.agentModels(
            installationID: installationID,
            projectID: self.selectedProjectID,
            modelID: defaultModel,
            useStoredDefault: false
          )
        } else {
          response = rawResponse
        }
        let effortModel =
          defaultModel.flatMap { selected in
            response.models.first(where: { $0.modelID == selected })
          } ?? response.models.first(where: { !$0.supportedReasoningEfforts.isEmpty })
        let effortWasRemoved =
          persistedDefault.effort.map { effort in
            effortModel?.supportedReasoningEfforts.contains(effort) != true
          } ?? false

        let correctedDefault: IPCAgentModelDefaultResponse?
        if defaultWasRemoved || effortWasRemoved,
          defaultRevision == self.agentModelDefaultRevision
        {
          correctedDefault = try await client.setAgentDefaults(
            providerID: providerID,
            model: defaultWasRemoved ? nil : defaultModel,
            permissionMode: providerID == "opencode" ? persistedDefault.permissionMode : nil,
            effort: nil
          )
          guard defaultRevision == self.agentModelDefaultRevision else { return }
        } else {
          correctedDefault = nil
        }

        guard !Task.isCancelled,
          catalogGeneration == self.agentModelCatalogGeneration,
          refreshGeneration == self.agentModelRefreshGeneration,
          defaultRevision == self.agentModelDefaultRevision
        else { return }
        self.agentModelOptions = response.models
        self.agentModelRefreshError = nil
        let finalDefault = correctedDefault ?? persistedDefault
        if self.openCodeDefaultModel != finalDefault.model {
          self.agentModelHydrationSuppression = AgentModelHydrationID(
            providerID: providerID,
            installationID: installationID,
            projectID: self.selectedProjectID,
            modelID: finalDefault.model
          )
        }
        if correctedDefault != nil {
          self.agentModelDefaultRevision &+= 1
        }
        self.openCodeDefaultModel = finalDefault.model
        self.openCodeDefaultPermissionMode = finalDefault.permissionMode
        self.openCodeDefaultEffort = finalDefault.effort

        let message: String
        if addedCount == 0, removedCount == 0 {
          message = "\(self.agentProviderName(providerID)) 模型列表已是最新（共 \(response.models.count) 个）"
        } else {
          message =
            "\(self.agentProviderName(providerID)) 模型列表已刷新：新增 \(addedCount) 个，移除 \(removedCount) 个"
        }
        self.postToast(message, symbol: "arrow.clockwise", tone: .success)
      } catch {
        guard catalogGeneration == self.agentModelCatalogGeneration,
          refreshGeneration == self.agentModelRefreshGeneration
        else { return }
        self.agentModelRefreshError = Self.message(error)
      }
    }
  }

  func registerAgentInstallation(
    providerID: String,
    displayName: String,
    executableURL: URL,
    configurationURL: URL? = nil
  ) {
    runAgentMutation(
      operation: { client in
        try await client.registerAgentInstallation(
          IPCAgentRegistrationRequest(
            providerID: providerID,
            displayName: displayName,
            executablePath: executableURL.standardizedFileURL.path,
            configurationPath: configurationURL?.standardizedFileURL.path
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
    effort: String? = nil,
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
            effort: effort,
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
  func consumeAgentModelHydrationSuppression(
    providerID: String = "opencode",
    installationID: String?,
    projectID: String?,
    modelID: String?
  ) -> Bool {
    let hydrationID = AgentModelHydrationID(
      providerID: providerID,
      installationID: installationID,
      projectID: projectID,
      modelID: modelID
    )
    guard agentModelHydrationSuppression == hydrationID else {
      agentModelHydrationSuppression = nil
      return false
    }
    agentModelHydrationSuppression = nil
    return true
  }

  func hydrateAgentModelState(
    installationID: String?,
    providerID: String = "opencode"
  ) async {
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

    let persistedDefault = try? await client.agentModelDefault(providerID: providerID)
    let modelResponse: IPCAgentModelsResponse?
    if let installationID, !installationID.isEmpty {
      modelResponse = try? await client.agentModels(
        installationID: installationID,
        projectID: selectedProjectID,
        modelID: persistedDefault?.model
      )
    } else {
      modelResponse = nil
    }

    guard !Task.isCancelled else { return }
    if catalogGeneration == agentModelCatalogGeneration, let modelResponse {
      agentModelOptions = modelResponse.models
    }
    guard defaultLoadGeneration == agentModelDefaultLoadGeneration,
      defaultRevision == agentModelDefaultRevision,
      let persistedDefault
    else { return }
    openCodeDefaultModel = persistedDefault.model
    openCodeDefaultPermissionMode = persistedDefault.permissionMode
    openCodeDefaultEffort = persistedDefault.effort
  }

  func saveAgentModelDefault(_ model: String?, providerID: String = "opencode") {
    agentModelCatalogGeneration &+= 1
    agentModelHydrationSuppression = nil
    saveAgentDefaults(
      providerID: providerID,
      model: model,
      permissionMode: providerID == "opencode" ? openCodeDefaultPermissionMode : nil,
      effort: nil
    )
  }

  func saveOpenCodePermissionMode(_ mode: String) {
    saveAgentDefaults(
      providerID: "opencode",
      model: openCodeDefaultModel,
      permissionMode: mode,
      effort: openCodeDefaultEffort
    )
  }

  func saveAgentEffort(_ effort: String?, providerID: String = "opencode") {
    saveAgentDefaults(
      providerID: providerID,
      model: openCodeDefaultModel,
      permissionMode: providerID == "opencode" ? openCodeDefaultPermissionMode : nil,
      effort: effort
    )
  }

  private func saveAgentDefaults(
    providerID: String,
    model: String?,
    permissionMode: String?,
    effort: String?
  ) {
    let previous = openCodeDefaultModel
    let previousPermissionMode = openCodeDefaultPermissionMode
    let previousEffort = openCodeDefaultEffort
    agentModelDefaultRevision &+= 1
    let revision = agentModelDefaultRevision
    openCodeDefaultModel = model
    if let permissionMode {
      openCodeDefaultPermissionMode = permissionMode
    }
    openCodeDefaultEffort = effort
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
        _ = try await client.setAgentDefaults(
          providerID: providerID,
          model: model,
          permissionMode: permissionMode,
          effort: effort
        )
        guard self.agentModelDefaultRevision == revision else { return }
        let persisted = try await client.agentModelDefault(providerID: providerID)
        guard self.agentModelDefaultRevision == revision else { return }
        self.openCodeDefaultModel = persisted.model
        self.openCodeDefaultPermissionMode = persisted.permissionMode
        self.openCodeDefaultEffort = persisted.effort
        self.postToast(
          "\(self.agentProviderName(providerID)) 默认设置已保存",
          symbol: "checkmark.circle.fill",
          tone: .success
        )
      } catch {
        guard self.agentModelDefaultRevision == revision else { return }
        self.openCodeDefaultModel = previous
        self.openCodeDefaultPermissionMode = previousPermissionMode
        self.openCodeDefaultEffort = previousEffort
        self.errorMessage = Self.message(error)
      }
    }
    agentModelDefaultMutationTask = task
  }

  private func agentProviderName(_ providerID: String) -> String {
    agentProviders.first(where: { $0.providerID == providerID })?.displayName ?? providerID
  }
}
