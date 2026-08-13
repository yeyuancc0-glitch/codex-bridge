import BridgePresentation
import Foundation

public enum BridgeAppModelError: Error, Equatable, Sendable {
  case approvalNotAuthorized
  case invalidStateSnapshot
}

actor BridgeAppActionRouter: BridgePresentationActionHandling {
  private let backend: any BridgeAppBackend
  private var revision: UInt64?
  private var approvalCapabilities: [String: BridgeApprovalCapability] = [:]

  init(backend: any BridgeAppBackend) {
    self.backend = backend
  }

  func install(
    capabilities: [BridgeApprovalCapability],
    revision newRevision: UInt64
  ) throws {
    if let revision, newRevision <= revision { return }
    var unique: [String: BridgeApprovalCapability] = [:]
    for capability in capabilities {
      guard unique.updateValue(capability, forKey: capability.approvalID) == nil else {
        throw BridgeAppModelError.invalidStateSnapshot
      }
    }
    revision = newRevision
    approvalCapabilities = unique
  }

  func reset() {
    revision = nil
    approvalCapabilities.removeAll(keepingCapacity: false)
  }

  func handle(_ action: PresentationAction) async throws {
    switch action {
    case .refresh(let destination):
      try await backend.refresh(destination)
    case .addProject:
      try await backend.addProject()
    case .openProject(let projectID):
      try await backend.openProject(projectID)
    case .removeProject(let projectID):
      try await backend.removeProject(projectID)
    case .updateProjectAccessPolicy(let projectID, let read, let write, let network):
      try await backend.updateProjectAccessPolicy(
        projectID: projectID,
        read: read,
        write: write,
        network: network
      )
    case .selectThreadProject(let projectID):
      try await backend.selectThreadProject(projectID)
    case .loadMoreThreads:
      try await backend.loadMoreThreads()
    case .readThreadHistory(let threadID):
      try await backend.readThreadHistory(threadID)
    case .readBoundThreadHistory(let projectID, let threadID):
      try await backend.readThreadHistory(projectID: projectID, threadID: threadID)
    case .loadMoreThreadHistory:
      try await backend.loadMoreThreadHistory()
    case .continueThread(let threadID):
      try await backend.continueThread(threadID)
    case .createTaskFromThread(let threadID):
      try await backend.createTaskFromThread(threadID)
    case .copyThreadID(let threadID):
      try await backend.copyThreadID(threadID)
    case .archiveSupervisorThread(let threadID):
      try await backend.archiveSupervisorThread(threadID)
    case .openThreadInCodex(let threadID):
      try await backend.openThreadInCodex(threadID)
    case .openBoundThreadInCodex(let projectID, let threadID):
      try await backend.openThreadInCodex(projectID: projectID, threadID: threadID)
    case .openTaskInCodex(let taskID):
      try await backend.openTaskInCodex(taskID)
    case .loadTaskEvidence(let taskID):
      try await backend.loadTaskEvidence(taskID)
    case .prepareReadOnlyTask(let projectID, let threadID):
      try await backend.prepareReadOnlyTask(projectID: projectID, threadID: threadID)
    case .dismissReadOnlyTask:
      try await backend.dismissReadOnlyTask()
    case .submitReadOnlyTask(let draft):
      try await backend.submitReadOnlyTask(draft)
    case .interruptTask(let taskID):
      try await backend.interruptTask(taskID)
    case .suspendAmbiguousTask(let taskID):
      try await backend.suspendAmbiguousTask(taskID)
    case .authorizeTaskVerification(let taskID):
      try await backend.authorizeTaskVerification(taskID)
    case .testConnection:
      try await backend.testConnection()
    case .setReceivingPaused(let paused):
      try await backend.setReceivingPaused(paused)
    case .exportSupportBundle:
      try await backend.exportSupportBundle()
    case .updateSetting(let key, let enabled):
      try await backend.updateSetting(key: key, enabled: enabled)
    case .decideTask(let requestID, let decision, let model, let effort):
      try await backend.resolveLocalTask(
        requestID: requestID,
        decision: decision,
        model: model,
        effort: effort
      )
    case .decideApproval(let approvalID, let decision):
      try await resolveApproval(
        approvalID: approvalID,
        taskID: nil,
        threadID: nil,
        turnID: nil,
        decision: decision
      )
    case .decideBoundApproval(let approvalID, let taskID, let threadID, let turnID, let decision):
      try await resolveApproval(
        approvalID: approvalID,
        taskID: taskID,
        threadID: threadID,
        turnID: turnID,
        decision: decision
      )
    }
  }

  func submit(_ submission: BridgeAppTaskSubmission) async throws -> BridgeAppTaskReceipt {
    try await backend.submit(submission)
  }

  func steer(_ request: BridgeAppSteerRequest) async throws {
    try await backend.steer(request)
  }

  func connect() async throws {
    try await backend.connect()
  }

  func disconnect() async throws {
    try await backend.disconnect()
  }

  private func resolveApproval(
    approvalID: String,
    taskID: String?,
    threadID: String?,
    turnID: String?,
    decision: PresentationApprovalDecision
  ) async throws {
    let capability = approvalCapabilities[approvalID]
    if decision == .allowOnce {
      guard let capability, capability.isComplete, capability.allowOnceEligible,
        capability.taskID == taskID, capability.threadID == threadID,
        capability.turnID == turnID
      else {
        throw BridgeAppModelError.approvalNotAuthorized
      }
    }
    try await backend.resolveCodexApproval(
      BridgeApprovalResolution(
        approvalID: approvalID,
        taskID: taskID,
        threadID: threadID,
        turnID: turnID,
        decision: decision,
        capability: decision == .allowOnce ? capability : nil
      )
    )
  }
}
