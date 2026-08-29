import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeProjects
import BridgeServiceCore
import Foundation

public struct ServiceConversationPage: Sendable {
  public let taskStatus: ServiceTaskStatus
  public let messages: [ServiceTaskMessageRecord]
  public let liveEntries: [TaskConversationBuffer.Entry]

  public init(
    taskStatus: ServiceTaskStatus,
    messages: [ServiceTaskMessageRecord],
    liveEntries: [TaskConversationBuffer.Entry] = []
  ) {
    self.taskStatus = taskStatus
    self.messages = messages
    self.liveEntries = liveEntries
  }
}

extension BridgeServiceApplication {
  public func serviceWorkbenchProjectID(
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    try Self.checkDeadline(deadline)
    guard let projectID = try await settings.string(for: .workbenchProjectID) else {
      return nil
    }
    guard !projectID.isEmpty, projectID.utf8.count <= 128, !projectID.contains("\0"),
      try await projects.project(id: ProjectID(rawValue: projectID)) != nil
    else {
      return nil
    }
    return projectID
  }

  public func serviceSetWorkbenchProjectID(
    _ projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    if let projectID {
      guard !projectID.isEmpty, projectID.utf8.count <= 128, !projectID.contains("\0"),
        try await projects.project(id: ProjectID(rawValue: projectID)) != nil
      else {
        throw BridgeMCPQueryError.projectNotFound
      }
    }
    try await settings.set(projectID, for: .workbenchProjectID)
  }

  public func serviceWorkbenchPermissionMode(
    deadline: ContinuousClock.Instant
  ) async throws -> ServicePermissionMode {
    try Self.checkDeadline(deadline)
    return try await settings.workbenchPermissionMode()
  }

  public func serviceSetWorkbenchPermissionMode(
    _ mode: ServicePermissionMode,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setWorkbenchPermissionMode(mode)
  }

  public func serviceRegisterManagedProject(
    name: String,
    rootURL: URL,
    accessPolicy: ProjectAccessPolicy,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    try Self.checkDeadline(deadline)
    let project = try await projects.register(
      name: name,
      rootURL: rootURL,
      accessPolicy: accessPolicy
    )
    return Self.projectDetail(project)
  }

  public func serviceUpdateManagedProjectPolicy(
    projectID: String,
    policy: ProjectAccessPolicy,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    try Self.checkDeadline(deadline)
    let project = try await projects.updateAccessPolicy(
      policy,
      projectID: ProjectID(rawValue: projectID)
    )
    return Self.projectDetail(project)
  }

  public func serviceUpdateManagedProjectCommands(
    projectID: String,
    commands: [ServiceWorkspaceCommand],
    blacklist: [ServiceCommandBlacklistRule],
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    try Self.checkDeadline(deadline)
    _ = try await projects.updateWorkspaceCommands(
      commands,
      commandBlacklist: blacklist,
      projectID: ProjectID(rawValue: projectID)
    )
    return Self.projectDetail(try await managedProject(projectID))
  }

  public func serviceSetManagedProjectCommandMode(
    projectID: String,
    mode: ServiceDirectCommandMode,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    try Self.checkDeadline(deadline)
    _ = try await projects.updateDirectCommandMode(
      mode,
      projectID: ProjectID(rawValue: projectID)
    )
    return Self.projectDetail(try await managedProject(projectID))
  }

  public func serviceRemoveManagedProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await projects.remove(projectID: ProjectID(rawValue: projectID))
  }

  public func serviceTasks(
    projectID: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> [MCPServiceTaskSnapshot] {
    try Self.checkDeadline(deadline)
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("tasks.limit")
    }
    let records = try await tasks.tasks(
      projectID: projectID.map { ProjectID(rawValue: $0) },
      limit: limit
    )
    var snapshots: [MCPServiceTaskSnapshot] = []
    snapshots.reserveCapacity(records.count)
    for record in records {
      snapshots.append(
        try await serviceTask(
          taskID: record.id.rawValue,
          recentEventLimit: 10,
          deadline: deadline
        )
      )
    }
    return snapshots
  }

  public func serviceStopTask(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    await coordinator.stop(taskID: TaskID(rawValue: taskID))
  }

  public func serviceDeleteTask(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    let id = TaskID(rawValue: taskID)
    try await tasks.remove(taskID: id)
    await coordinator.purgeConversation(taskID: id)
  }

  public func serviceConversationPage(
    taskID: String,
    beforeMessageID: Int64?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceConversationPage {
    try Self.checkDeadline(deadline)
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("conversation.limit")
    }
    let records = try await coordinator.conversationPage(
      taskID: TaskID(rawValue: taskID),
      beforeMessageID: beforeMessageID,
      limit: limit
    )
    guard let task = try await tasks.task(id: TaskID(rawValue: taskID)) else {
      throw ServiceStoreError.unknownTask(TaskID(rawValue: taskID))
    }
    let liveEntries: [TaskConversationBuffer.Entry]
    if beforeMessageID == nil {
      liveEntries = try await coordinator.liveConversationEntries(
        taskID: TaskID(rawValue: taskID)
      )
    } else {
      liveEntries = []
    }
    return ServiceConversationPage(
      taskStatus: task.state.status,
      messages: records,
      liveEntries: liveEntries
    )
  }

  public func serviceSubscribeConversation(
    taskID: String,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> ConversationSubscription {
    try Self.checkDeadline(deadline)
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("conversation.limit")
    }
    return try await coordinator.subscribeConversation(
      taskID: TaskID(rawValue: taskID),
      limit: limit
    )
  }

  public func serviceUnsubscribeConversation(
    taskID: TaskID,
    subscriptionID: Int
  ) async {
    await coordinator.unsubscribeConversation(
      taskID: taskID,
      subscriptionID: subscriptionID
    )
  }

  public func serviceExposureMode() async throws -> ServiceMCPExposureMode {
    try await settings.exposureMode()
  }

  public func serviceSupervisorEnabled() async throws -> Bool {
    try await settings.isSupervisorEnabled()
  }
}
