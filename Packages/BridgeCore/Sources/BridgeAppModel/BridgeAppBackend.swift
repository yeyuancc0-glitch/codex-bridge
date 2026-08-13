import BridgePresentation
import Foundation

public enum BridgeAppConnectionState: String, Equatable, Sendable {
  case stopped
  case starting
  case authenticating
  case connecting
  case ready
  case degraded
  case failed
}

public struct BridgeApprovalCapability: Equatable, Sendable {
  public let approvalID: String
  public let taskID: String
  public let threadID: String
  public let turnID: String
  public let operationID: String
  public let authorizationHandle: String
  public let allowOnceEligible: Bool

  public init(
    approvalID: String,
    taskID: String,
    threadID: String,
    turnID: String,
    operationID: String,
    authorizationHandle: String,
    allowOnceEligible: Bool
  ) {
    self.approvalID = approvalID
    self.taskID = taskID
    self.threadID = threadID
    self.turnID = turnID
    self.operationID = operationID
    self.authorizationHandle = authorizationHandle
    self.allowOnceEligible = allowOnceEligible
  }

  public var isComplete: Bool {
    !approvalID.isEmpty && !taskID.isEmpty && !threadID.isEmpty && !turnID.isEmpty
      && !operationID.isEmpty && !authorizationHandle.isEmpty
  }
}

public struct BridgeAppStateSnapshot: Equatable, Sendable {
  public let revision: UInt64
  public let connectionState: BridgeAppConnectionState
  public let presentation: BridgePresentationSnapshot
  public let pendingSheet: PresentedBridgeSheet?
  public let approvalCapabilities: [BridgeApprovalCapability]

  public init(
    revision: UInt64,
    connectionState: BridgeAppConnectionState,
    presentation: BridgePresentationSnapshot,
    pendingSheet: PresentedBridgeSheet? = nil,
    approvalCapabilities: [BridgeApprovalCapability] = []
  ) {
    self.revision = revision
    self.connectionState = connectionState
    self.presentation = presentation
    self.pendingSheet = pendingSheet
    self.approvalCapabilities = approvalCapabilities
  }
}

public struct BridgeAppTaskSubmission: Equatable, Sendable {
  public let requestID: String
  public let projectID: String
  public let threadID: String?
  public let goal: String
  public let acceptanceCriteria: [String]
  public let model: String
  public let effort: String
  public let permissionMode: String
  public let networkAllowed: Bool

  public init(
    requestID: String,
    projectID: String,
    threadID: String? = nil,
    goal: String,
    acceptanceCriteria: [String],
    model: String,
    effort: String,
    permissionMode: String,
    networkAllowed: Bool
  ) {
    self.requestID = requestID
    self.projectID = projectID
    self.threadID = threadID
    self.goal = goal
    self.acceptanceCriteria = acceptanceCriteria
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.networkAllowed = networkAllowed
  }
}

public struct BridgeAppTaskReceipt: Equatable, Sendable {
  public let taskID: String
  public let reusedExistingTask: Bool

  public init(taskID: String, reusedExistingTask: Bool) {
    self.taskID = taskID
    self.reusedExistingTask = reusedExistingTask
  }
}

public struct BridgeAppSteerRequest: Equatable, Sendable {
  public let taskID: String
  public let expectedTurnID: String
  public let input: String

  public init(taskID: String, expectedTurnID: String, input: String) {
    self.taskID = taskID
    self.expectedTurnID = expectedTurnID
    self.input = input
  }
}

public struct BridgeApprovalResolution: Equatable, Sendable {
  public let approvalID: String
  public let taskID: String?
  public let threadID: String?
  public let turnID: String?
  public let decision: PresentationApprovalDecision
  public let capability: BridgeApprovalCapability?

  public init(
    approvalID: String,
    taskID: String? = nil,
    threadID: String? = nil,
    turnID: String? = nil,
    decision: PresentationApprovalDecision,
    capability: BridgeApprovalCapability?
  ) {
    self.approvalID = approvalID
    self.taskID = taskID
    self.threadID = threadID
    self.turnID = turnID
    self.decision = decision
    self.capability = capability
  }
}

public protocol BridgeAppBackend: Sendable {
  func stateUpdates() async -> AsyncThrowingStream<BridgeAppStateSnapshot, Error>
  func refresh(_ destination: BridgeNavigationDestination) async throws
  func submit(_ submission: BridgeAppTaskSubmission) async throws -> BridgeAppTaskReceipt
  func steer(_ request: BridgeAppSteerRequest) async throws
  func interruptTask(_ taskID: String) async throws
  func suspendAmbiguousTask(_ taskID: String) async throws
  func authorizeTaskVerification(_ taskID: String) async throws
  func resolveLocalTask(
    requestID: String,
    decision: PresentationTaskDecision,
    model: String,
    effort: String
  ) async throws
  func resolveCodexApproval(_ resolution: BridgeApprovalResolution) async throws
  func connect() async throws
  func disconnect() async throws
  func testConnection() async throws
  func setReceivingPaused(_ paused: Bool) async throws
  func addProject() async throws
  func openProject(_ projectID: String) async throws
  func selectThreadProject(_ projectID: String) async throws
  func loadMoreThreads() async throws
  func readThreadHistory(_ threadID: String) async throws
  func readThreadHistory(projectID: String, threadID: String) async throws
  func loadMoreThreadHistory() async throws
  func continueThread(_ threadID: String) async throws
  func createTaskFromThread(_ threadID: String) async throws
  func copyThreadID(_ threadID: String) async throws
  func archiveSupervisorThread(_ threadID: String) async throws
  func openThreadInCodex(_ threadID: String) async throws
  func openThreadInCodex(projectID: String, threadID: String) async throws
  func openTaskInCodex(_ taskID: String) async throws
  func loadTaskEvidence(_ taskID: String) async throws
  func prepareReadOnlyTask(projectID: String?, threadID: String?) async throws
  func dismissReadOnlyTask() async throws
  func submitReadOnlyTask(_ draft: ReadOnlyTaskDraftPresentation) async throws
  func exportSupportBundle() async throws
  func updateSetting(key: String, enabled: Bool) async throws
}

public enum BridgeAppBackendCompatibilityError: Error, Equatable, Sendable {
  case verificationAuthorizationUnsupported
  case threadCatalogOperationUnsupported
  case localTaskComposerUnsupported
  case taskEvidenceUnsupported
  case recoveryResolutionUnsupported
}

extension BridgeAppBackend {
  public func suspendAmbiguousTask(_ taskID: String) async throws {
    _ = taskID
    throw BridgeAppBackendCompatibilityError.recoveryResolutionUnsupported
  }

  public func loadTaskEvidence(_ taskID: String) async throws {
    _ = taskID
    throw BridgeAppBackendCompatibilityError.taskEvidenceUnsupported
  }

  public func authorizeTaskVerification(_ taskID: String) async throws {
    _ = taskID
    throw BridgeAppBackendCompatibilityError.verificationAuthorizationUnsupported
  }

  public func selectThreadProject(_ projectID: String) async throws {
    _ = projectID
    throw BridgeAppBackendCompatibilityError.threadCatalogOperationUnsupported
  }

  public func loadMoreThreads() async throws {
    throw BridgeAppBackendCompatibilityError.threadCatalogOperationUnsupported
  }

  public func readThreadHistory(projectID: String, threadID: String) async throws {
    _ = (projectID, threadID)
    throw BridgeAppBackendCompatibilityError.threadCatalogOperationUnsupported
  }

  public func loadMoreThreadHistory() async throws {
    throw BridgeAppBackendCompatibilityError.threadCatalogOperationUnsupported
  }

  public func openThreadInCodex(projectID: String, threadID: String) async throws {
    _ = (projectID, threadID)
    throw BridgeAppBackendCompatibilityError.threadCatalogOperationUnsupported
  }

  public func prepareReadOnlyTask(projectID: String?, threadID: String?) async throws {
    _ = (projectID, threadID)
    throw BridgeAppBackendCompatibilityError.localTaskComposerUnsupported
  }

  public func dismissReadOnlyTask() async throws {
    throw BridgeAppBackendCompatibilityError.localTaskComposerUnsupported
  }

  public func submitReadOnlyTask(_ draft: ReadOnlyTaskDraftPresentation) async throws {
    _ = draft
    throw BridgeAppBackendCompatibilityError.localTaskComposerUnsupported
  }
}
