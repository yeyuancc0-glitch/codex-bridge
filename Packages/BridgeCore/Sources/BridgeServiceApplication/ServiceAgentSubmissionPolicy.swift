import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore

struct ServiceAgentSubmissionPolicy: Sendable {
  let providerID: AgentProviderID
  let configuredModel: String?
  let configuredEffort: String?
  let defaultPermissionMode: ServicePermissionMode
  let readOnlyOnly: Bool
  let selectionsRequireObservedCapabilities: Bool
}

extension BridgeServiceApplication {
  func agentSubmissionPolicy(
    providerID: AgentProviderID
  ) async throws -> ServiceAgentSubmissionPolicy {
    switch providerID {
    case .openCode:
      let configuredMode = try await settings.openCodeDefaultPermissionMode()
      return ServiceAgentSubmissionPolicy(
        providerID: providerID,
        configuredModel: try await settings.string(for: .openCodeDefaultModel),
        configuredEffort: try await settings.openCodeDefaultEffort(),
        defaultPermissionMode: configuredMode == "plan" ? .readOnly : .workspaceWrite,
        readOnlyOnly: false,
        selectionsRequireObservedCapabilities: false
      )

    case .antigravity:
      return ServiceAgentSubmissionPolicy(
        providerID: providerID,
        configuredModel: nil,
        configuredEffort: nil,
        defaultPermissionMode: .readOnly,
        readOnlyOnly: true,
        selectionsRequireObservedCapabilities: true
      )

    default:
      throw BridgeMCPQueryError.contractRejected
    }
  }
}
