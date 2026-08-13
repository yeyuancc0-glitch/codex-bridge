import BridgePresentation

@testable import BridgeAppModel

enum BackendEvent: Equatable, Sendable {
  case refresh(BridgeNavigationDestination)
  case submit(BridgeAppTaskSubmission)
  case steer(BridgeAppSteerRequest)
  case interrupt(String)
  case connect
  case disconnect
  case testConnection
  case receivingPaused(Bool)
  case openTask(String)
  case openThread(String)
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
  func readThreadHistory(_ threadID: String) {}
  func continueThread(_ threadID: String) {}
  func createTaskFromThread(_ threadID: String) {}
  func copyThreadID(_ threadID: String) {}
  func archiveSupervisorThread(_ threadID: String) {}
  func openThreadInCodex(_ threadID: String) { recordedEvents.append(.openThread(threadID)) }
  func openTaskInCodex(_ taskID: String) { recordedEvents.append(.openTask(taskID)) }
  func exportSupportBundle() {}
  func updateSetting(key: String, enabled: Bool) {}
}
