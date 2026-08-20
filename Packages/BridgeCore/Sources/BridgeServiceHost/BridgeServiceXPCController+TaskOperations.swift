import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceXPCController {
  func handleListThreads(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCThreadListRequest.self,
      from: request
    )
    let page = try await composition.application.serviceAppThreads(
      projectID: payload.projectID,
      cursor: payload.cursor,
      limit: payload.limit,
      search: payload.search,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: page
    )
  }

  func handleListSkills(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCProjectSkillsRequest.self,
      from: request
    )
    let skills = try await composition.application.serviceListSkills(
      projectID: payload.projectID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: skills
    )
  }

  func handleReadThread(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCThreadReadRequest.self,
      from: request
    )
    let page = try await composition.application.serviceAppReadThread(
      projectID: payload.projectID,
      threadID: payload.threadID,
      detail: payload.detail,
      cursor: payload.cursor,
      limit: payload.limit,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: page
    )
  }

  func handleListTasks(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload =
      try BridgeServiceIPCCodec.optionalPayload(
        IPCTaskListRequest.self,
        from: request
      ) ?? IPCTaskListRequest()
    guard (1...500).contains(payload.limit) else {
      throw ServiceStoreError.invalidArgument("tasks.limit")
    }
    let projectID = payload.projectID.map(ProjectID.init(rawValue:))
    let taskList = try await composition.tasks.tasks(
      projectID: projectID,
      limit: payload.limit
    )
    var snapshots: [MCPServiceTaskSnapshot] = []
    snapshots.reserveCapacity(taskList.count)
    for task in taskList {
      snapshots.append(
        try await composition.application.serviceTask(
          taskID: task.id.rawValue,
          recentEventLimit: 10,
          deadline: Self.deadline()
        )
      )
    }
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCTaskListResponse(tasks: snapshots)
    )
  }

  func handleGetTask(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
    let task = try await composition.application.serviceTask(
      taskID: payload.taskID,
      recentEventLimit: payload.recentEventLimit,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: task
    )
  }

  func handleStopTask(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
    await composition.coordinator.stop(taskID: TaskID(rawValue: payload.taskID))
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleDeleteTask(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
    let taskID = TaskID(rawValue: payload.taskID)
    try await composition.tasks.remove(taskID: taskID)
    await composition.coordinator.purgeConversation(taskID: taskID)
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }
}
