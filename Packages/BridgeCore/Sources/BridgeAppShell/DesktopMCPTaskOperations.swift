import BridgeApplication
import BridgeDomain
import BridgeMCP
import Foundation

actor DesktopMCPTaskOperations: BridgeMCPTaskOperations {
  private let application: BridgeApplicationService
  private let admission = DesktopMCPTaskAdmission()
  private let supervisorAvailable: Bool

  init(application: BridgeApplicationService, supervisorAvailable: Bool = false) {
    self.application = application
    self.supervisorAvailable = supervisorAvailable
  }

  func configure(requiresHealthyRemote: Bool) async {
    await admission.configure(requiresHealthyRemote: requiresHealthyRemote)
  }

  func setRemoteAdmissionCheck(
    _ check: (@Sendable () async -> Bool)?
  ) async {
    await admission.setRemoteCheck(check)
  }

  func setRemoteAdmissionLeaseCheck(
    _ check: (@Sendable () async -> DesktopRemoteAdmissionLease?)?
  ) async {
    await admission.setRemoteLeaseCheck(check)
  }

  func getTask(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskSnapshot {
    let snapshot = try await application.getTask(taskID: taskID, deadline: deadline)
    guard !supervisorAvailable else { return snapshot }
    return MCPTaskSnapshot(
      taskID: snapshot.taskID,
      phase: snapshot.phase,
      activity: snapshot.activity,
      threadID: snapshot.threadID,
      turnID: snapshot.turnID,
      currentPlan: snapshot.currentPlan,
      currentStep: snapshot.currentStep,
      supervisorState: "unavailable",
      changedFileCount: snapshot.changedFileCount,
      verificationSummary: snapshot.verificationSummary,
      finalReportAvailable: snapshot.finalReportAvailable,
      updatedAt: snapshot.updatedAt
    )
  }

  func getTaskEvents(
    taskID: String,
    afterSequence: Int64?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskEventPage {
    try await application.getTaskEvents(
      taskID: taskID,
      afterSequence: afterSequence,
      limit: limit,
      deadline: deadline
    )
  }

  func getTaskDiff(
    taskID: String,
    cursor: String?,
    limit: Int,
    includePatch: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskDiffPage {
    try await application.getTaskDiff(
      taskID: taskID,
      cursor: cursor,
      limit: limit,
      includePatch: includePatch,
      deadline: deadline
    )
  }

  func getFinalReport(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFinalReport {
    try await application.getFinalReport(taskID: taskID, deadline: deadline)
  }

  func submitTask(
    _ submission: TaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskSubmissionReceipt {
    guard supervisorAvailable else { throw BridgeMCPQueryError.unavailable }
    let lease = try await admission.acquireSubmissionLease()
    defer { lease?.release() }
    return try await application.submitTask(submission, deadline: deadline)
  }

  func steerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt {
    try await application.steerTask(
      taskID: taskID,
      expectedTurnID: expectedTurnID,
      input: input,
      deadline: deadline
    )
  }

  func interruptTask(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt {
    try await application.interruptTask(taskID: taskID, deadline: deadline)
  }

  func interruptTask(
    taskID: String,
    expectedTurnID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskMutationReceipt {
    try await application.interruptTask(
      taskID: taskID,
      expectedTurnID: expectedTurnID,
      deadline: deadline
    )
  }
}

actor DesktopMCPTaskAdmission {
  private var requiresHealthyRemote = false
  private var remoteCheck: (@Sendable () async -> Bool)?
  private var remoteLeaseCheck: (@Sendable () async -> DesktopRemoteAdmissionLease?)?

  func configure(requiresHealthyRemote: Bool) {
    self.requiresHealthyRemote = requiresHealthyRemote
  }

  func setRemoteCheck(_ check: (@Sendable () async -> Bool)?) {
    remoteCheck = check
  }

  func setRemoteLeaseCheck(
    _ check: (@Sendable () async -> DesktopRemoteAdmissionLease?)?
  ) {
    remoteLeaseCheck = check
  }

  func requireSubmissionAllowed() async throws {
    let lease = try await acquireSubmissionLease()
    lease?.release()
  }

  func acquireSubmissionLease() async throws -> DesktopRemoteAdmissionLease? {
    guard requiresHealthyRemote else { return nil }
    if let remoteLeaseCheck {
      guard let lease = await remoteLeaseCheck() else {
        throw BridgeMCPQueryError.unavailable
      }
      return lease
    }
    guard let remoteCheck, await remoteCheck() else {
      throw BridgeMCPQueryError.unavailable
    }
    return nil
  }
}
