import BridgeIPC
import Foundation

extension BridgeServiceAppModel {
  func refreshAgentModelCatalog(
    installationID: String?,
    providerID: String = "opencode"
  ) {
    guard !agentModelRefreshingProviders.contains(providerID) else { return }
    guard let installationID, !installationID.isEmpty else {
      setAgentModelRefreshError(
        "暂无已启用且可用的 \(agentProviderName(providerID)) 安装。",
        providerID: providerID
      )
      return
    }

    incrementAgentModelCatalogGeneration(for: providerID)
    let catalogGeneration = agentModelCatalogGeneration(for: providerID)
    incrementAgentModelRefreshGeneration(for: providerID)
    let refreshGeneration = agentModelRefreshGeneration(for: providerID)
    incrementAgentModelDefaultLoadGeneration(for: providerID)
    let previousMutation = agentModelDefaultMutationTasks[providerID]
    let projectID = selectedProjectID
    setAgentModelsHydrating(false, providerID: providerID)
    setAgentModelsRefreshing(true, providerID: providerID)
    setAgentModelRefreshError(nil, providerID: providerID)

    Task { [weak self, previousMutation] in
      guard let self else { return }
      defer {
        if self.agentModelRefreshGeneration(for: providerID) == refreshGeneration {
          self.setAgentModelsRefreshing(false, providerID: providerID)
        }
      }

      do {
        await previousMutation?.value
        guard !Task.isCancelled,
          catalogGeneration == self.agentModelCatalogGeneration(for: providerID)
        else { return }
        let defaultRevision = self.agentModelDefaultRevision(for: providerID)
        let client = try self.currentClient()
        let persistedDefault = try await client.agentModelDefault(providerID: providerID)
        guard !Task.isCancelled,
          defaultRevision == self.agentModelDefaultRevision(for: providerID)
        else { return }
        let defaultModel = persistedDefault.model
        let rawResponse = try await client.agentModels(
          installationID: installationID,
          projectID: projectID,
          modelID: nil,
          useStoredDefault: false
        )
        guard !Task.isCancelled,
          catalogGeneration == self.agentModelCatalogGeneration(for: providerID),
          refreshGeneration == self.agentModelRefreshGeneration(for: providerID),
          defaultRevision == self.agentModelDefaultRevision(for: providerID)
        else { return }

        let previousIDs = Set(self.agentModelOptions(for: providerID).map(\.modelID))
        let currentIDs = Set(rawResponse.models.map(\.modelID))
        let addedCount = currentIDs.subtracting(previousIDs).count
        let removedCount = previousIDs.subtracting(currentIDs).count
        let defaultWasRemoved = defaultModel.map { !currentIDs.contains($0) } ?? false
        let response: IPCAgentModelsResponse
        if let defaultModel, !defaultWasRemoved, providerID != "deepseek-harness" {
          response = try await client.agentModels(
            installationID: installationID,
            projectID: projectID,
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
          defaultRevision == self.agentModelDefaultRevision(for: providerID)
        {
          correctedDefault = try await client.setAgentDefaults(
            providerID: providerID,
            model: defaultWasRemoved ? nil : defaultModel,
            permissionMode: providerID == "opencode" ? persistedDefault.permissionMode : nil,
            effort: nil
          )
          guard defaultRevision == self.agentModelDefaultRevision(for: providerID) else {
            return
          }
        } else {
          correctedDefault = nil
        }

        guard !Task.isCancelled,
          catalogGeneration == self.agentModelCatalogGeneration(for: providerID),
          refreshGeneration == self.agentModelRefreshGeneration(for: providerID),
          defaultRevision == self.agentModelDefaultRevision(for: providerID)
        else { return }
        self.setAgentModelOptions(response.models, providerID: providerID)
        self.setAgentModelRefreshError(nil, providerID: providerID)
        let finalDefault = correctedDefault ?? persistedDefault
        if self.agentModelDefault(for: providerID).model != finalDefault.model {
          self.agentModelHydrationSuppressions[providerID] = AgentModelHydrationID(
            providerID: providerID,
            installationID: installationID,
            projectID: projectID,
            modelID: finalDefault.model
          )
        }
        if correctedDefault != nil {
          self.incrementAgentModelDefaultRevision(for: providerID)
        }
        self.applyAgentModelDefault(finalDefault, providerID: providerID)

        let message: String
        if addedCount == 0, removedCount == 0 {
          message = "\(self.agentProviderName(providerID)) 模型列表已是最新（共 \(response.models.count) 个）"
        } else {
          message =
            "\(self.agentProviderName(providerID)) 模型列表已刷新：新增 \(addedCount) 个，移除 \(removedCount) 个"
        }
        self.postToast(message, symbol: "arrow.clockwise", tone: .success)
      } catch {
        guard catalogGeneration == self.agentModelCatalogGeneration(for: providerID),
          refreshGeneration == self.agentModelRefreshGeneration(for: providerID)
        else { return }
        self.setAgentModelRefreshError(Self.message(error), providerID: providerID)
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
    guard agentModelHydrationSuppressions[providerID] == hydrationID else {
      agentModelHydrationSuppressions.removeValue(forKey: providerID)
      return false
    }
    agentModelHydrationSuppressions.removeValue(forKey: providerID)
    return true
  }

  func hydrateAgentModelState(
    installationID: String?,
    providerID: String = "opencode"
  ) async {
    incrementAgentModelCatalogGeneration(for: providerID)
    let catalogGeneration = agentModelCatalogGeneration(for: providerID)
    incrementAgentModelDefaultLoadGeneration(for: providerID)
    let defaultLoadGeneration = agentModelDefaultLoadGeneration(for: providerID)
    let projectID = selectedProjectID
    let normalizedInstallationID = installationID.flatMap { $0.isEmpty ? nil : $0 }
    let scope = AgentModelCatalogScope(
      installationID: normalizedInstallationID,
      projectID: projectID
    )
    if agentModelCatalogScopes[providerID] != scope {
      agentModelCatalogScopes[providerID] = scope
      setAgentModelOptions([], providerID: providerID)
    }
    agentModelHydrationGenerations[providerID] = catalogGeneration
    setAgentModelsHydrating(true, providerID: providerID)
    defer {
      if agentModelHydrationGenerations[providerID] == catalogGeneration {
        setAgentModelsHydrating(false, providerID: providerID)
      }
    }

    if let mutation = agentModelDefaultMutationTasks[providerID] {
      await mutation.value
    }
    guard !Task.isCancelled else { return }
    let defaultRevision = agentModelDefaultRevision(for: providerID)
    guard let client = try? currentClient() else { return }

    let persistedDefault = try? await client.agentModelDefault(providerID: providerID)
    let modelResponse: IPCAgentModelsResponse?
    if let installationID = normalizedInstallationID {
      let rawResponse = try? await client.agentModels(
        installationID: installationID,
        projectID: projectID,
        modelID: nil,
        useStoredDefault: false
      )
      if let rawResponse,
        let defaultModel = persistedDefault?.model,
        rawResponse.models.contains(where: { $0.modelID == defaultModel })
      {
        modelResponse =
          (try? await client.agentModels(
            installationID: installationID,
            projectID: projectID,
            modelID: defaultModel,
            useStoredDefault: false
          )) ?? rawResponse
      } else {
        modelResponse = rawResponse
      }
    } else {
      modelResponse = nil
    }

    guard !Task.isCancelled else { return }
    if catalogGeneration == agentModelCatalogGeneration(for: providerID), let modelResponse {
      setAgentModelOptions(modelResponse.models, providerID: providerID)
    }
    guard defaultLoadGeneration == agentModelDefaultLoadGeneration(for: providerID),
      defaultRevision == agentModelDefaultRevision(for: providerID),
      let persistedDefault
    else { return }
    applyAgentModelDefault(persistedDefault, providerID: providerID)
  }

  func saveAgentModelDefault(_ model: String?, providerID: String = "opencode") {
    incrementAgentModelCatalogGeneration(for: providerID)
    agentModelHydrationSuppressions.removeValue(forKey: providerID)
    let current = agentModelDefault(for: providerID)
    saveAgentDefaults(
      providerID: providerID,
      model: model,
      permissionMode: current.permissionMode,
      effort: nil
    )
  }

  func saveOpenCodePermissionMode(_ mode: String) {
    saveAgentPermissionMode(mode, providerID: "opencode")
  }

  func saveAgentPermissionMode(_ mode: String, providerID: String) {
    let current = agentModelDefault(for: providerID)
    saveAgentDefaults(
      providerID: providerID,
      model: current.model,
      permissionMode: mode,
      effort: current.effort
    )
  }

  func saveAgentEffort(_ effort: String?, providerID: String = "opencode") {
    let current = agentModelDefault(for: providerID)
    saveAgentDefaults(
      providerID: providerID,
      model: current.model,
      permissionMode: current.permissionMode,
      effort: effort
    )
  }

  private func saveAgentDefaults(
    providerID: String,
    model: String?,
    permissionMode: String?,
    effort: String?
  ) {
    let previous = agentModelDefault(for: providerID)
    incrementAgentModelDefaultRevision(for: providerID)
    let revision = agentModelDefaultRevision(for: providerID)
    applyAgentModelDefault(
      IPCAgentModelDefaultResponse(
        providerID: providerID,
        model: model,
        permissionMode: permissionMode ?? previous.permissionMode,
        effort: effort
      ),
      providerID: providerID
    )
    let previousMutation = agentModelDefaultMutationTasks[providerID]
    let task = Task { [weak self, previousMutation] in
      await previousMutation?.value
      guard let self, !Task.isCancelled else { return }
      defer {
        if self.agentModelDefaultRevision(for: providerID) == revision {
          self.agentModelDefaultMutationTasks.removeValue(forKey: providerID)
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
        guard self.agentModelDefaultRevision(for: providerID) == revision else { return }
        let persisted = try await client.agentModelDefault(providerID: providerID)
        guard self.agentModelDefaultRevision(for: providerID) == revision else { return }
        self.applyAgentModelDefault(persisted, providerID: providerID)
        self.postToast(
          "\(self.agentProviderName(providerID)) 默认设置已保存",
          symbol: "checkmark.circle.fill",
          tone: .success
        )
      } catch {
        guard self.agentModelDefaultRevision(for: providerID) == revision else { return }
        self.applyAgentModelDefault(previous, providerID: providerID)
        self.errorMessage = Self.message(error)
      }
    }
    agentModelDefaultMutationTasks[providerID] = task
  }

  private func agentProviderName(_ providerID: String) -> String {
    agentProviders.first(where: { $0.providerID == providerID })?.displayName ?? providerID
  }

  private func applyAgentModelDefault(
    _ value: IPCAgentModelDefaultResponse,
    providerID: String
  ) {
    agentModelDefaults[providerID] = value
    guard providerID == "opencode" else { return }
    openCodeDefaultModel = value.model
    openCodeDefaultPermissionMode = value.permissionMode
    openCodeDefaultEffort = value.effort
  }

  private func incrementAgentModelCatalogGeneration(for providerID: String) {
    agentModelCatalogGenerations[providerID, default: 0] &+= 1
  }

  private func agentModelCatalogGeneration(for providerID: String) -> UInt64 {
    agentModelCatalogGenerations[providerID, default: 0]
  }

  private func incrementAgentModelRefreshGeneration(for providerID: String) {
    agentModelRefreshGenerations[providerID, default: 0] &+= 1
  }

  private func agentModelRefreshGeneration(for providerID: String) -> UInt64 {
    agentModelRefreshGenerations[providerID, default: 0]
  }

  private func incrementAgentModelDefaultLoadGeneration(for providerID: String) {
    agentModelDefaultLoadGenerations[providerID, default: 0] &+= 1
  }

  private func agentModelDefaultLoadGeneration(for providerID: String) -> UInt64 {
    agentModelDefaultLoadGenerations[providerID, default: 0]
  }

  private func incrementAgentModelDefaultRevision(for providerID: String) {
    agentModelDefaultRevisions[providerID, default: 0] &+= 1
  }

  private func agentModelDefaultRevision(for providerID: String) -> UInt64 {
    agentModelDefaultRevisions[providerID, default: 0]
  }

  private func setAgentModelOptions(
    _ options: [IPCAgentModelSummary],
    providerID: String
  ) {
    if providerID == "opencode" {
      agentModelOptions = options
    } else {
      agentModelOptionsByProvider[providerID] = options
    }
  }

  private func setAgentModelsRefreshing(_ refreshing: Bool, providerID: String) {
    if refreshing {
      agentModelRefreshingProviders.insert(providerID)
    } else {
      agentModelRefreshingProviders.remove(providerID)
    }
    if providerID == "opencode" {
      isRefreshingAgentModels = refreshing
    }
  }

  private func setAgentModelsHydrating(_ hydrating: Bool, providerID: String) {
    if hydrating {
      agentModelHydratingProviders.insert(providerID)
    } else {
      agentModelHydrationGenerations.removeValue(forKey: providerID)
      agentModelHydratingProviders.remove(providerID)
    }
  }

  private func setAgentModelRefreshError(_ error: String?, providerID: String) {
    if let error {
      agentModelRefreshErrorsByProvider[providerID] = error
    } else {
      agentModelRefreshErrorsByProvider.removeValue(forKey: providerID)
    }
    if providerID == "opencode" {
      agentModelRefreshError = error
    }
  }
}
