import BridgeCodexService
import BridgeDeepSeekHarnessACP
import BridgeIPC
import BridgeMCP
import BridgeServiceCore
import BridgeTunnel
import Foundation

extension BridgeServiceRequestController {
  static func map(_ error: Error) -> BridgeServiceIPCError {
    if error is BridgeServiceIPCCodecError {
      return .init(code: "invalid_request", message: "The XPC request is invalid.")
    }
    if let error = error as? ServiceLocalMCPError {
      return mapLocalMCPError(error)
    }
    if let error = error as? ServiceMCPClientRegistryError {
      return mapMCPClientRegistryError(error)
    }
    if let error = error as? ServiceAgentRegistryError {
      return mapAgentRegistryError(error)
    }
    if let error = error as? DeepSeekHarnessACPError {
      return mapDeepSeekHarnessError(error)
    }
    if let error = error as? ServiceStoreError {
      return mapStoreError(error)
    }
    if let error = error as? BridgeMCPQueryError {
      return mapMCPQueryError(error)
    }
    if error is TunnelConfigurationError {
      return .init(
        code: "invalid_tunnel_configuration",
        message: "The Tunnel configuration is invalid."
      )
    }
    if let error = error as? ServiceTunnelError {
      return mapTunnelError(error)
    }
    if error is ExecutionServiceError {
      return .init(
        code: "execution_failed",
        message: "The provider operation failed.",
        retryable: true
      )
    }
    return .init(
      code: "internal_error",
      message: "The service operation failed.",
      retryable: true
    )
  }

  private static func mapLocalMCPError(_ error: ServiceLocalMCPError) -> BridgeServiceIPCError {
    switch error {
    case .localPortUnavailable:
      return .init(
        code: "local_port_unavailable",
        message: "The configured local MCP port is unavailable.",
        retryable: true
      )
    case .endpointManagedByConfiguration:
      return .init(
        code: "endpoint_managed_by_configuration",
        message: "The local MCP endpoint is managed by the service configuration."
      )
    }
  }

  private static func mapMCPClientRegistryError(
    _ error: ServiceMCPClientRegistryError
  ) -> BridgeServiceIPCError {
    switch error {
    case .unsupportedClient:
      return .init(code: "invalid_client", message: "The MCP client is unsupported.")
    case .clientDisabled:
      return .init(code: "client_disabled", message: "The MCP client is disabled.")
    }
  }

  private static func mapAgentRegistryError(
    _ error: ServiceAgentRegistryError
  ) -> BridgeServiceIPCError {
    switch error {
    case .providerUnavailable:
      return .init(
        code: "agent_provider_unavailable",
        message: "The Agent Provider adapter is unavailable."
      )
    case .installationUnavailable:
      return .init(
        code: "agent_installation_unavailable",
        message: "The Agent installation must pass Probe before it can be enabled."
      )
    case .installationNeedsReview:
      return .init(
        code: "agent_installation_needs_review",
        message: "The Agent executable changed and requires explicit local review."
      )
    case .registrationInProgress:
      return .init(
        code: "agent_registration_in_progress",
        message: "This Agent executable is already being registered.",
        retryable: true
      )
    }
  }

  private static func mapDeepSeekHarnessError(
    _ error: DeepSeekHarnessACPError
  ) -> BridgeServiceIPCError {
    switch error {
    case .artifactInvalid(let field):
      return .init(
        code: "agent_artifact_invalid",
        message:
          "The selected DeepSeek Harness build is incomplete or incompatible (\(field)). Use the pinned dsh-v0.1.1-rc.2 build and select packages/examples/acp-demo/lib/bin.js."
      )
    case .templateMismatch:
      return .init(
        code: "agent_configuration_mismatch",
        message:
          "The selected cordis.yml must retain the Codex Bridge read-only profile structure. Only the model catalog, default model, thinking mode, and reasoning effort may differ."
      )
    case .nodeVersionIncompatible:
      return .init(
        code: "agent_runtime_incompatible",
        message: "DeepSeek Harness requires Node ^22.19.0 or >=24.0.0."
      )
    case .processUnavailable:
      return .init(
        code: "agent_runtime_unavailable",
        message: "The DeepSeek Harness Node runtime could not be launched."
      )
    case .processExited:
      return .init(
        code: "agent_runtime_probe_failed",
        message: "The DeepSeek Harness Node version probe failed."
      )
    default:
      return .init(
        code: "agent_validation_failed",
        message: "The DeepSeek Harness installation could not be validated."
      )
    }
  }

  private static func mapStoreError(_ error: ServiceStoreError) -> BridgeServiceIPCError {
    switch error {
    case .unknownProject:
      return .init(code: "project_not_found", message: "The project is unavailable.")
    case .unknownTask:
      return .init(code: "task_not_found", message: "The task is unavailable.")
    case .unknownAgentInstallation:
      return .init(
        code: "agent_installation_not_found",
        message: "The Agent installation is unavailable."
      )
    case .duplicateAgentInstallation, .duplicateAgentExecutable:
      return .init(
        code: "duplicate_agent_installation",
        message: "The Agent executable is already registered."
      )
    case .activeWriteTaskExists:
      return .init(
        code: "busy",
        message: "The project already has an active write task.",
        retryable: true
      )
    case .idempotencyConflict, .duplicateTask:
      return .init(
        code: "idempotency_conflict",
        message: "The request identifier is already in use."
      )
    case .invalidArgument, .invalidTaskTransition, .immutableTaskChanged:
      return .init(
        code: "invalid_state",
        message: "The operation is invalid for the current state."
      )
    case .duplicateProject, .duplicateProjectRoot:
      return .init(
        code: "duplicate_project",
        message: "The project root is already registered."
      )
    case .corruptSchema, .corruptRecord, .unsupportedSchemaVersion, .storageFailure:
      return .init(
        code: "unavailable",
        message: "The local service store is unavailable.",
        retryable: true
      )
    }
  }

  private static func mapTunnelError(_ error: ServiceTunnelError) -> BridgeServiceIPCError {
    switch error {
    case .invalidRuntimeKey, .invalidStoredConfiguration:
      return .init(code: "invalid_tunnel_configuration", message: error.localizedDescription)
    case .notConfigured:
      return .init(code: "tunnel_not_configured", message: error.localizedDescription)
    case .helperUnavailable:
      return .init(code: "tunnel_helper_unavailable", message: error.localizedDescription)
    case .secretStoreUnavailable:
      return .init(code: "keychain_unavailable", message: error.localizedDescription)
    case .localMCPUnavailable, .serviceStopped, .startFailed:
      return .init(
        code: "tunnel_unavailable",
        message: error.localizedDescription,
        retryable: true
      )
    }
  }
}
