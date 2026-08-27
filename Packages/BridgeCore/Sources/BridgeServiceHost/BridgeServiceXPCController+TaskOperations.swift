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
    let snapshots = try await composition.application.serviceTasks(
      projectID: payload.projectID,
      limit: payload.limit,
      deadline: Self.deadline()
    )
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
    try await composition.application.serviceStopTask(
      taskID: payload.taskID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleSteerTask(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCTaskSteerRequest.self, from: request)
    try Self.validateTaskControl(payload)
    let receipt = try await composition.application.serviceSteerTask(
      taskID: payload.taskID,
      expectedTurnID: payload.expectedTurnID,
      input: payload.input,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: receipt
    )
  }

  func handleInterruptTask(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCTaskInterruptRequest.self, from: request)
    try Self.validateTaskControl(payload.taskID, expectedTurnID: payload.expectedTurnID)
    let receipt = try await composition.application.serviceInterruptTask(
      taskID: payload.taskID,
      expectedTurnID: payload.expectedTurnID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: receipt
    )
  }

  private static func validateTaskControl(_ request: IPCTaskSteerRequest) throws {
    try validateTaskControl(request.taskID, expectedTurnID: request.expectedTurnID)
    guard !request.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      request.input.utf8.count <= IPCTaskSteerRequest.maximumInputBytes,
      !request.input.contains("\0")
    else {
      throw BridgeMCPQueryError.contractRejected
    }
  }

  private static func validateTaskControl(
    _ taskID: String,
    expectedTurnID: String
  ) throws {
    guard !taskID.isEmpty,
      taskID.utf8.count <= IPCTaskInterruptRequest.maximumIdentifierBytes,
      !taskID.contains("\0"),
      !expectedTurnID.isEmpty,
      expectedTurnID.utf8.count <= IPCTaskInterruptRequest.maximumIdentifierBytes,
      !expectedTurnID.contains("\0")
    else {
      throw BridgeMCPQueryError.contractRejected
    }
  }

  func handleDeleteTask(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCTaskRequest.self, from: request)
    try await composition.application.serviceDeleteTask(
      taskID: payload.taskID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }
}
