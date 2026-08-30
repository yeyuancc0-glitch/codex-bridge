import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPProvider {
  public func models(
    installation: AgentInstallation,
    projectRoot: String?,
    selectedModelID _: String?
  ) async throws -> [AgentModelDescriptor] {
    guard installation.providerID == .deepSeekHarness else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let fallback = try configuration.launchBuilder.profile.modelDescriptors(
      for: installation,
      selectedModelID: nil
    )
    let catalogRoot = try makeProbeRoot(projectRoot)
    let runDirectory: String
    do {
      runDirectory = try makeRunDirectory(prefix: "catalog-run")
    } catch {
      cleanup(runDirectory: nil, probeRoot: catalogRoot)
      throw error
    }
    var client: DeepSeekHarnessACPClient?
    do {
      let launch = try configuration.launchBuilder.make(
        installation: installation,
        projectRoot: catalogRoot.path,
        runDirectory: runDirectory,
        networkAllowed: false,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      try validate(initialization)
      let session = try await connected.newSession(cwd: catalogRoot.path)
      await connected.shutdown()
      cleanup(runDirectory: launch.runDirectory, probeRoot: catalogRoot)
      guard
        let modelOption = session.configOptions.first(where: {
          $0.id == "model" || $0.category == "model"
        }), !modelOption.values.isEmpty
      else {
        return fallback
      }
      let efforts = fallback.first?.supportedReasoningEfforts ?? []
      let defaultEffort = fallback.first?.defaultReasoningEffort
      return try modelOption.values.map { model in
        try AgentModelDescriptor(
          id: model.value,
          displayName: model.name,
          supportedReasoningEfforts: efforts,
          defaultReasoningEffort: defaultEffort
        )
      }
    } catch {
      await client?.shutdown()
      cleanup(runDirectory: runDirectory, probeRoot: catalogRoot)
      throw error
    }
  }
}
