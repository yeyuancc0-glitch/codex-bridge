import BridgeAgentCore
import Foundation

extension OpenCodeACPProvider {
  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard request.installation.providerID == .openCode else {
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
    var client: OpenCodeACPClient?

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
      let version = try validate(initialization)
      let installation = try AgentInstallation(
        id: request.installation.id,
        providerID: .openCode,
        executablePath: launch.resolvedExecutablePath,
        version: version,
        protocolRevision: String(initialization.protocolVersion)
      )
      let capabilities = capabilities(initialization)
      await connected.shutdown()
      cleanup(runDirectory: launch.runDirectory, probeRoot: probeRoot)
      return AgentProbeResult(
        installation: installation,
        available: true,
        capabilities: capabilities
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

  func validate(_ initialization: OpenCodeACPInitialization) throws -> String {
    guard initialization.protocolVersion == 1 else {
      throw AgentRuntimeError.unsupportedProtocol(String(initialization.protocolVersion))
    }
    guard initialization.agentName?.caseInsensitiveCompare("OpenCode") == .orderedSame else {
      throw AgentRuntimeError.unsupportedProtocol("unexpected_agent")
    }
    guard let version = initialization.agentVersion,
      configuration.compatibility.accepts(version: version)
    else {
      throw AgentRuntimeError.unsupportedProtocol(
        initialization.agentVersion ?? "missing_opencode_version"
      )
    }
    return version
  }

  func unavailableProbe(
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

  private static func probeReason(_ error: any Error) -> String {
    let base: String
    switch error {
    case OpenCodeACPError.unsupportedProtocol(let version):
      base = "OpenCode uses unsupported ACP protocol version \(version)."
    case AgentRuntimeError.unsupportedProtocol(let value):
      base = "OpenCode version or identity is incompatible: \(value)."
    case AgentRuntimeError.installationUnavailable:
      base = "OpenCode executable is unavailable or unsafe."
    case AgentRuntimeError.processUnavailable:
      base = "The required local process or read-only sandbox is unavailable."
    case AgentRuntimeError.modelUnavailable(let model):
      base = "The selected OpenCode model is unavailable: \(model)."
    case OpenCodeACPError.requestTimedOut:
      base = "OpenCode ACP initialization timed out."
    case OpenCodeACPError.processExited(let code):
      let value = code.map { String($0) } ?? "unknown"
      base = "OpenCode ACP exited during initialization (code: \(value))."
    default:
      base = "OpenCode ACP probe failed."
    }
    let detail = String(describing: error)
    if detail == base || detail.isEmpty { return base }
    let truncated = detail.prefix(300)
    return "\(base) (\(truncated))"
  }

  private static func requiresReview(_ error: any Error) -> Bool {
    switch error {
    case OpenCodeACPError.unsupportedProtocol,
      AgentRuntimeError.unsupportedProtocol:
      return true
    default:
      return false
    }
  }
}

struct ProbeRoot: Sendable {
  let path: String
  let owned: Bool
}
