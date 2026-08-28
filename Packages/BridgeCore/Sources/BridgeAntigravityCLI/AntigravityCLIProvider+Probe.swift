import BridgeAgentCore
import BridgeProcess
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension AntigravityCLIProvider {
  public func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard request.installation.providerID == .antigravity else {
      return unavailableProbe(
        request.installation,
        reason: "Installation belongs to another provider."
      )
    }
    guard
      FileManager.default.isExecutableFile(
        atPath: configuration.launchBuilder.sandboxExecutablePath
      )
    else {
      return unavailableProbe(
        request.installation,
        reason: "The macOS read-only process boundary is unavailable."
      )
    }

    do {
      let resolved = try Self.resolvedExecutable(request.installation.executablePath)
      let environment = try configuration.launchBuilder.commandEnvironment(
        executablePath: resolved,
        sourceEnvironment: configuration.sourceEnvironment
      )
      let result = try await configuration.commandRunner.run(
        argv: [resolved, "--version"],
        workingDirectory: request.projectRoot,
        environment: environment,
        timeout: configuration.requestTimeout
      )
      guard !result.timedOut else { throw AntigravityCLIError.requestTimedOut }
      guard Self.succeeded(result.termination) else {
        throw Self.processError(result.termination)
      }
      let output = result.standardOutput.tail + "\n" + result.standardError.tail
      guard let version = AntigravityCLISemanticVersion(output) else {
        throw AntigravityCLIError.unsupportedVersion("unrecognized")
      }
      guard configuration.compatibility.accepts(version) else {
        throw AntigravityCLIError.unsupportedVersion(version.stringValue)
      }
      let help = try await configuration.commandRunner.run(
        argv: [resolved, "--help"],
        workingDirectory: request.projectRoot,
        environment: environment,
        timeout: configuration.requestTimeout
      )
      guard !help.timedOut else { throw AntigravityCLIError.requestTimedOut }
      guard Self.succeeded(help.termination) else {
        throw Self.processError(help.termination)
      }
      guard !help.standardOutput.truncated, !help.standardError.truncated else {
        throw AgentRuntimeError.unsupportedProtocol("antigravity-help-output")
      }
      let facts = AntigravityCLIHelpFacts.parse(
        help.standardOutput.tail + "\n" + help.standardError.tail
      )
      guard facts.supportsStreamJSON, facts.supportsPlanMode else {
        throw AgentRuntimeError.unsupportedProtocol("antigravity-stream-json-plan")
      }
      let installation = try AgentInstallation(
        id: request.installation.id,
        providerID: .antigravity,
        executablePath: resolved,
        version: version.stringValue,
        protocolRevision: "stream-json-v1"
      )
      return AgentProbeResult(
        installation: installation,
        available: true,
        capabilities: Self.capabilities(observed: facts.observedCapabilities)
      )
    } catch {
      return unavailableProbe(
        request.installation,
        reason: Self.probeReason(error),
        reviewRequired: Self.requiresReview(error)
      )
    }
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

  static func succeeded(_ termination: ManagedProcessTermination) -> Bool {
    if case .exited(0) = termination { return true }
    return false
  }

  static func processError(_ termination: ManagedProcessTermination) -> AntigravityCLIError {
    switch termination {
    case .exited(let code): .processExited(code)
    case .killed: .processExited(nil)
    case .notStarted: .processExited(nil)
    }
  }

  static func probeReason(_ error: any Error) -> String {
    switch error {
    case AntigravityCLIError.unsupportedVersion(let version):
      "Antigravity CLI version is incompatible: \(version)."
    case AntigravityCLIError.requestTimedOut:
      "Antigravity CLI capability Probe timed out."
    case AgentRuntimeError.unsupportedProtocol(let protocolID):
      "Antigravity CLI does not support the required protocol surface: \(protocolID)."
    case AgentRuntimeError.installationUnavailable:
      "The Antigravity CLI executable is unavailable or unsafe."
    case AntigravityCLIError.processExited(let code):
      "Antigravity CLI capability Probe exited with code \(code.map(String.init) ?? "unknown")."
    default:
      "Antigravity CLI capability Probe failed."
    }
  }

  static func requiresReview(_ error: any Error) -> Bool {
    if case AntigravityCLIError.unsupportedVersion = error { return true }
    return false
  }

  static func resolvedExecutable(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
    }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    var metadata = stat()
    guard stat(resolved, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      access(resolved, X_OK) == 0,
      metadata.st_uid == getuid() || metadata.st_uid == 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0
    else {
      throw AgentRuntimeError.installationUnavailable(AgentInstallationID(rawValue: path))
    }
    return resolved
  }
}
