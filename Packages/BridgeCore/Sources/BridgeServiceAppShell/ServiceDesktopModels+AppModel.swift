import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func selectedAgentInstallation(
    providerID: String,
    installationID: String?
  ) -> IPCAgentInstallationSummary? {
    guard let installationID else { return nil }
    return agentInstallations.first {
      $0.providerID == providerID && $0.installationID == installationID
    }
  }

  func supportsAgentEffortSelection(
    providerID: String,
    installationID: String?
  ) -> Bool {
    if providerID == "opencode" {
      guard
        selectedAgentInstallation(
          providerID: providerID,
          installationID: installationID
        ) != nil
      else { return false }
      return agentSelectedModel(for: providerID)?.supportedReasoningEfforts.isEmpty == false
    }
    guard
      let installation = selectedAgentInstallation(
        providerID: providerID,
        installationID: installationID
      )
    else {
      return providerID != "antigravity"
    }
    return installation.supportsEffortSelection
  }
}
