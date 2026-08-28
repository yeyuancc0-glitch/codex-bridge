import BridgeIPC

struct AgentModelCatalogResolution {
  let response: IPCAgentModelsResponse
  let addedCount: Int
  let removedCount: Int
  let defaultWasRemoved: Bool
  let effortWasRemoved: Bool
}

enum AgentModelCatalogResolver {
  static func defaultModelWasRemoved(
    _ defaultModel: String?,
    from response: IPCAgentModelsResponse
  ) -> Bool {
    defaultModel.map { model in
      !response.models.contains(where: { $0.modelID == model })
    } ?? false
  }

  static func resolve(
    previousOptions: [IPCAgentModelSummary],
    catalogResponse: IPCAgentModelsResponse,
    response: IPCAgentModelsResponse,
    defaultModel: String?,
    persistedEffort: String?,
    defaultWasRemoved: Bool
  ) -> AgentModelCatalogResolution {
    let previousIDs = Set(previousOptions.map(\.modelID))
    let currentIDs = Set(catalogResponse.models.map(\.modelID))
    let effortModel =
      defaultModel.flatMap { selected in
        response.models.first(where: { $0.modelID == selected })
      } ?? response.models.first(where: { !$0.supportedReasoningEfforts.isEmpty })
    let effortWasRemoved =
      persistedEffort.map { effort in
        effortModel?.supportedReasoningEfforts.contains(effort) != true
      } ?? false
    return AgentModelCatalogResolution(
      response: response,
      addedCount: currentIDs.subtracting(previousIDs).count,
      removedCount: previousIDs.subtracting(currentIDs).count,
      defaultWasRemoved: defaultWasRemoved,
      effortWasRemoved: effortWasRemoved
    )
  }
}
