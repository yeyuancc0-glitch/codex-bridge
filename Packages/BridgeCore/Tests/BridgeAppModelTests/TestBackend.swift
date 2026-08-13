import BridgePresentation

@testable import BridgeAppModel

enum BackendEvent: Equatable, Sendable {
  case refresh(BridgeNavigationDestination)
  case submit(BridgeAppTaskSubmission)
  case steer(BridgeAppSteerRequest)
  case interrupt(String)
  case suspendAmbiguous(String)
  case authorizeVerification(String)
  case connect
  case disconnect
  case testConnection
  case receivingPaused(Bool)
  case openTask(String)
  case reconnectProject(String)
  case removeProject(String)
  case updateProjectPolicy(
    projectID: String,
    read: ProjectPermissionPresentation,
    write: ProjectPermissionPresentation,
    network: ProjectPermissionPresentation
  )
  case loadTaskEvidence(String)
  case openThread(String)
  case openBoundThread(projectID: String, threadID: String)
  case selectThreadProject(String)
  case readBoundHistory(projectID: String, threadID: String)
  case prepareReadOnly(projectID: String?, threadID: String?)
  case submitReadOnly(ReadOnlyTaskDraftPresentation)
}

actor TestBackend: BridgeAppBackend {
  private let stream: AsyncThrowingStream<BridgeAppStateSnapshot, Error>
  private let continuation: AsyncThrowingStream<BridgeAppStateSnapshot, Error>.Continuation
  private var recordedEvents: [BackendEvent] = []
  private var recordedResolutions: [BridgeApprovalResolution] = []

  init() {
    let pair = AsyncThrowingStream<BridgeAppStateSnapshot, Error>.makeStream()
    stream = pair.stream
    continuation = pair.continuation
  }

  func stateUpdates() -> AsyncThrowingStream<BridgeAppStateSnapshot, Error> { stream }
  func emit(_ snapshot: BridgeAppStateSnapshot) { continuation.yield(snapshot) }
  func finish() { continuation.finish() }
  func events() -> [BackendEvent] { recordedEvents }
  func resolutions() -> [BridgeApprovalResolution] { recordedResolutions }

  func refresh(_ destination: BridgeNavigationDestination) {
    recordedEvents.append(.refresh(destination))
  }

  func submit(_ submission: BridgeAppTaskSubmission) -> BridgeAppTaskReceipt {
    recordedEvents.append(.submit(submission))
    return BridgeAppTaskReceipt(taskID: "task-1", reusedExistingTask: false)
  }

  func steer(_ request: BridgeAppSteerRequest) { recordedEvents.append(.steer(request)) }
  func interruptTask(_ taskID: String) { recordedEvents.append(.interrupt(taskID)) }
  func suspendAmbiguousTask(_ taskID: String) {
    recordedEvents.append(.suspendAmbiguous(taskID))
  }
  func authorizeTaskVerification(_ taskID: String) {
    recordedEvents.append(.authorizeVerification(taskID))
  }

  func resolveLocalTask(
    requestID _: String,
    decision _: PresentationTaskDecision,
    model _: String,
    effort _: String
  ) {}

  func resolveCodexApproval(_ resolution: BridgeApprovalResolution) {
    recordedResolutions.append(resolution)
  }

  func connect() { recordedEvents.append(.connect) }
  func disconnect() { recordedEvents.append(.disconnect) }
  func testConnection() { recordedEvents.append(.testConnection) }
  func setReceivingPaused(_ paused: Bool) { recordedEvents.append(.receivingPaused(paused)) }
  func addProject() {}
  func openProject(_ projectID: String) {}
  func reconnectProject(_ projectID: String) {
    recordedEvents.append(.reconnectProject(projectID))
  }
  func removeProject(_ projectID: String) {
    recordedEvents.append(.removeProject(projectID))
  }
  func updateProjectAccessPolicy(
    projectID: String,
    read: ProjectPermissionPresentation,
    write: ProjectPermissionPresentation,
    network: ProjectPermissionPresentation
  ) {
    recordedEvents.append(
      .updateProjectPolicy(
        projectID: projectID,
        read: read,
        write: write,
        network: network
      )
    )
  }
  func selectThreadProject(_ projectID: String) {
    recordedEvents.append(.selectThreadProject(projectID))
  }
  func loadMoreThreads() {}
  func readThreadHistory(_ threadID: String) {}
  func readThreadHistory(projectID: String, threadID: String) {
    recordedEvents.append(.readBoundHistory(projectID: projectID, threadID: threadID))
  }
  func loadMoreThreadHistory() {}
  func continueThread(_ threadID: String) {}
  func createTaskFromThread(_ threadID: String) {}
  func copyThreadID(_ threadID: String) {}
  func archiveSupervisorThread(_ threadID: String) {}
  func openThreadInCodex(_ threadID: String) { recordedEvents.append(.openThread(threadID)) }
  func openThreadInCodex(projectID: String, threadID: String) {
    recordedEvents.append(.openBoundThread(projectID: projectID, threadID: threadID))
  }
  func openTaskInCodex(_ taskID: String) { recordedEvents.append(.openTask(taskID)) }
  func loadTaskEvidence(_ taskID: String) {
    recordedEvents.append(.loadTaskEvidence(taskID))
  }
  func prepareReadOnlyTask(projectID: String?, threadID: String?) {
    recordedEvents.append(.prepareReadOnly(projectID: projectID, threadID: threadID))
  }
  func dismissReadOnlyTask() {}
  func submitReadOnlyTask(_ draft: ReadOnlyTaskDraftPresentation) {
    recordedEvents.append(.submitReadOnly(draft))
  }
  func exportSupportBundle() {}
  func updateSetting(key: String, enabled: Bool) {}
}
