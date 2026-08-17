import BridgeMCP
import Foundation

public enum BridgeServiceClientError: Error, Equatable, LocalizedError, Sendable {
  case unavailable
  case invalidRemoteProxy
  case responseFailed

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "Codex Bridge Service is unavailable."
    case .invalidRemoteProxy:
      "Codex Bridge Service returned an invalid XPC proxy."
    case .responseFailed:
      "Codex Bridge Service did not return a valid response."
    }
  }
}

public actor BridgeServiceClient {
  private let connection: NSXPCConnection
  private var invalidated = false

  public init(machServiceName: String = BridgeServiceIPC.machServiceName) {
    precondition(!machServiceName.isEmpty)
    connection = NSXPCConnection(machServiceName: machServiceName)
    connection.remoteObjectInterface = NSXPCInterface(
      with: CodexBridgeServiceXPCProtocol.self
    )
    connection.resume()
  }

  public init(endpoint: NSXPCListenerEndpoint) {
    connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.remoteObjectInterface = NSXPCInterface(
      with: CodexBridgeServiceXPCProtocol.self
    )
    connection.resume()
  }

  public func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    connection.invalidate()
  }

  public func status() async throws -> BridgeStatusSnapshot {
    try await call(operation: .status, payload: Optional<IPCMutationResponse>.none)
  }

  public func projects() async throws -> [MCPProjectSummary] {
    let response: IPCProjectListResponse = try await call(
      operation: .listProjects,
      payload: Optional<IPCMutationResponse>.none
    )
    return response.projects
  }

  public func registerProject(
    _ request: IPCProjectRegistrationRequest
  ) async throws -> MCPProjectDetail {
    try await call(operation: .registerProject, payload: request)
  }

  public func updateProjectPolicy(
    _ request: IPCProjectPolicyRequest
  ) async throws -> MCPProjectDetail {
    try await call(operation: .updateProjectPolicy, payload: request)
  }

  public func removeProject(projectID: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .removeProject,
      payload: IPCProjectIDRequest(projectID: projectID)
    )
  }

  public func models() async throws -> MCPModelList {
    try await call(operation: .listModels, payload: Optional<IPCMutationResponse>.none)
  }

  public func threads(_ request: IPCThreadListRequest) async throws -> MCPThreadPage {
    try await call(operation: .listThreads, payload: request)
  }

  public func readThread(_ request: IPCThreadReadRequest) async throws -> MCPThreadReadPage {
    try await call(operation: .readThread, payload: request)
  }

  public func tasks(_ request: IPCTaskListRequest = .init()) async throws
    -> [MCPServiceTaskSnapshot]
  {
    let response: IPCTaskListResponse = try await call(
      operation: .listTasks,
      payload: request
    )
    return response.tasks
  }

  public func task(_ request: IPCTaskRequest) async throws -> MCPServiceTaskSnapshot {
    try await call(operation: .getTask, payload: request)
  }

  public func approveTask(taskID: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .approveTask,
      payload: IPCTaskRequest(taskID: taskID)
    )
  }

  public func rejectTask(taskID: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .rejectTask,
      payload: IPCTaskRequest(taskID: taskID)
    )
  }

  public func stopTask(taskID: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .stopTask,
      payload: IPCTaskRequest(taskID: taskID)
    )
  }

  public func approvals(taskID: String? = nil) async throws -> [IPCApprovalSummary] {
    let response: IPCApprovalListResponse = try await call(
      operation: .listApprovals,
      payload: IPCApprovalListRequest(taskID: taskID)
    )
    return response.approvals
  }

  public func resolveApproval(
    _ request: IPCApprovalResolutionRequest
  ) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .resolveApproval,
      payload: request
    )
  }

  public func setExposureMode(_ mode: MCPServiceExposureMode) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setExposureMode,
      payload: IPCExposureModeRequest(exposureMode: mode)
    )
  }

  private func call<Payload: Encodable, Response: Decodable>(
    operation: BridgeServiceIPCOperation,
    payload: Payload?
  ) async throws -> Response {
    guard !invalidated else { throw BridgeServiceClientError.unavailable }
    let requestID = UUID().uuidString.lowercased()
    let data = try BridgeServiceIPCCodec.request(
      operation: operation,
      payload: payload,
      requestID: requestID
    )
    let response = try await perform(data)
    return try BridgeServiceIPCCodec.decodeResponse(
      Response.self,
      data: response,
      requestID: requestID
    )
  }

  private func perform(_ data: Data) async throws -> Data {
    let proxy: CodexBridgeServiceXPCProtocol
    do {
      guard
        let value = connection.remoteObjectProxyWithErrorHandler({ _ in })
          as? CodexBridgeServiceXPCProtocol
      else {
        throw BridgeServiceClientError.invalidRemoteProxy
      }
      proxy = value
    } catch {
      throw BridgeServiceClientError.invalidRemoteProxy
    }

    return try await withCheckedThrowingContinuation { continuation in
      let completion = XPCClientCompletion(continuation)
      proxy.perform(data) { response in
        completion.resume(returning: response)
      }
    }
  }
}

private final class XPCClientCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, any Error>?

  init(_ continuation: CheckedContinuation<Data, any Error>) {
    self.continuation = continuation
  }

  func resume(returning data: Data) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: data)
  }
}
