import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceAppModel {
  public func registerProject(at url: URL) {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.registerProject(
        IPCProjectRegistrationRequest(
          name: url.lastPathComponent,
          absolutePath: url.standardizedFileURL.path
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  func updateProjectPolicy(
    projectID: String,
    draft: BridgeProjectPolicyDraft
  ) {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.updateProjectPolicy(
        IPCProjectPolicyRequest(
          projectID: projectID,
          readPermission: draft.readPermission,
          writePermission: draft.writePermission,
          networkPermission: draft.networkPermission
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func removeProject(_ projectID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.removeProject(projectID: projectID)
      if self.selectedProjectID == projectID {
        self.selectedProjectID = nil
        self.threads = []
        self.selectedThread = nil
      }
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func selectProject(_ projectID: String?) {
    selectedProjectID = projectID
    selectedThread = nil
    threads = []
    guard let projectID else { return }
    Task { [weak self] in
      await self?.loadThreads(projectID: projectID)
    }
  }

  public func openThread(_ threadID: String) {
    guard let projectID = selectedProjectID else { return }
    runMutation { [weak self] client in
      guard let self else { return }
      let page = try await client.readThread(
        IPCThreadReadRequest(
          projectID: projectID,
          threadID: threadID,
          detail: .full,
          limit: 200
        )
      )
      guard self.selectedProjectID == projectID else { return }
      self.selectedThread = page
    }
  }

  public func approveTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.approveTask(taskID: taskID)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func rejectTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.rejectTask(taskID: taskID)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func stopTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.stopTask(taskID: taskID)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func resolveApproval(_ approval: IPCApprovalSummary, allow: Bool) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.resolveApproval(
        IPCApprovalResolutionRequest(
          taskID: approval.taskID,
          approvalID: approval.approvalID,
          decision: allow ? "allow" : "deny"
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func setExposureMode(_ mode: MCPServiceExposureMode) {
    updateExposureState(mode)
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setExposureMode(mode)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func configureTunnel(tunnelID: String, runtimeKey: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.configureTunnel(
        IPCTunnelConfigurationRequest(
          tunnelID: tunnelID,
          runtimeKey: runtimeKey
        )
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func connectTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.connectTunnel()
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func disconnectTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.disconnectTunnel()
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func clearTunnel() {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.clearTunnel()
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  func loadThreads(projectID: String) async {
    do {
      let client = try currentClient()
      let page = try await client.threads(
        IPCThreadListRequest(projectID: projectID, limit: 100)
      )
      guard selectedProjectID == projectID else { return }
      threads = page.threads
    } catch {
      guard selectedProjectID == projectID else { return }
      threads = []
      errorMessage = Self.message(error)
    }
  }
}
