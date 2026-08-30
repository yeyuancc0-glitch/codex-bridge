import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPProvider {
  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard request.installation.providerID == .deepSeekHarness else {
      return unavailableProbe(
        request.installation,
        reason: "Installation belongs to another provider."
      )
    }
    let probeRoot: ProbeRoot
    do {
      probeRoot = try makeProbeRoot(request.projectRoot)
    } catch {
      return unavailableProbe(request.installation, reason: "Probe workspace is unavailable.")
    }
    let runDirectory: String
    do {
      runDirectory = try makeRunDirectory(prefix: "probe-run")
    } catch {
      cleanup(runDirectory: nil, probeRoot: probeRoot)
      return unavailableProbe(request.installation, reason: "Probe runtime is unavailable.")
    }
    var client: DeepSeekHarnessACPClient?
    do {
      let launch = try configuration.launchBuilder.make(
        installation: request.installation,
        projectRoot: probeRoot.path,
        runDirectory: runDirectory,
        networkAllowed: false,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let connected = makeClient(transport: try configuration.transportFactory(launch))
      client = connected
      let initialization = try await connected.initialize()
      try validate(initialization)
      _ = try await connected.newSession(cwd: probeRoot.path)
      await connected.shutdown()
      cleanup(runDirectory: launch.runDirectory, probeRoot: probeRoot)
      let installation = try AgentInstallation(
        id: request.installation.id,
        providerID: .deepSeekHarness,
        executablePath: launch.resolvedExecutablePath,
        version: DeepSeekHarnessACPConstants.releaseVersion,
        protocolRevision: String(DeepSeekHarnessACPConstants.acpProtocolVersion),
        artifacts: request.installation.artifacts
      )
      return AgentProbeResult(
        installation: installation,
        available: true,
        capabilities: Self.capabilitySnapshot
      )
    } catch {
      await client?.shutdown()
      cleanup(runDirectory: runDirectory, probeRoot: probeRoot)
      return unavailableProbe(
        request.installation,
        reason: Self.probeReason(error),
        reviewRequired: Self.requiresReview(error)
      )
    }
  }

  private func unavailableProbe(
    _ installation: AgentInstallation,
    reason: String,
    reviewRequired: Bool = false
  ) -> AgentProbeResult {
    AgentProbeResult(
      installation: installation,
      available: false,
      reviewRequired: reviewRequired,
      capabilities: .empty,
      unavailableReason: reason
    )
  }
}
