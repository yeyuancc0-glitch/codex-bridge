import BridgeDomain
import BridgeIPC
import BridgeProjects
import BridgeServiceCore
import Foundation

extension BridgeServiceXPCController {
  func handleListProjects(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let page = try await composition.application.serviceProjects(
      cursor: nil,
      limit: 100,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCProjectListResponse(projects: page.projects)
    )
  }

  func handleRegisterProject(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCProjectRegistrationRequest.self,
      from: request
    )
    let policy = try Self.projectPolicy(
      read: payload.readPermission,
      write: payload.writePermission,
      network: payload.networkPermission
    )
    let project = try await composition.projects.register(
      name: payload.name,
      rootURL: try Self.absoluteDirectoryURL(payload.absolutePath),
      accessPolicy: policy
    )
    let detail = try await composition.application.serviceProject(
      projectID: project.id.rawValue,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: detail
    )
  }

  func handleUpdateProjectPolicy(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCProjectPolicyRequest.self,
      from: request
    )
    _ = try await composition.projects.updateAccessPolicy(
      try Self.projectPolicy(
        read: payload.readPermission,
        write: payload.writePermission,
        network: payload.networkPermission
      ),
      projectID: ProjectID(rawValue: payload.projectID)
    )
    let detail = try await composition.application.serviceProject(
      projectID: payload.projectID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: detail
    )
  }

  func handleGetProjectCommands(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCProjectCommandsRequest.self,
      from: request
    )
    let detail = try await composition.application.serviceProject(
      projectID: payload.projectID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: detail
    )
  }

  func handleUpdateProjectCommands(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCProjectCommandsUpdateRequest.self,
      from: request
    )
    _ = try await composition.projects.updateWorkspaceCommands(
      try Self.workspaceCommands(payload.commands),
      commandBlacklist: try Self.blacklistRules(payload.commandBlacklist),
      projectID: ProjectID(rawValue: payload.projectID)
    )
    let updatedCommands = try await composition.application.serviceProject(
      projectID: payload.projectID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: updatedCommands
    )
  }

  func handleSetProjectCommandMode(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCProjectCommandModeUpdateRequest.self,
      from: request
    )
    guard let mode = ServiceDirectCommandMode(rawValue: payload.commandMode) else {
      throw ServiceStoreError.invalidArgument("project.commandMode")
    }
    _ = try await composition.projects.updateDirectCommandMode(
      mode,
      projectID: ProjectID(rawValue: payload.projectID)
    )
    let updatedMode = try await composition.application.serviceProject(
      projectID: payload.projectID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: updatedMode
    )
  }

  func handleRemoveProject(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCProjectIDRequest.self,
      from: request
    )
    let taskList = try await composition.tasks.tasks(
      projectID: ProjectID(rawValue: payload.projectID),
      limit: 500
    )
    guard taskList.allSatisfy({ $0.state.status.isTerminal }) else {
      throw ServiceStoreError.invalidArgument("project.activeTasks")
    }
    try await composition.projects.remove(
      projectID: ProjectID(rawValue: payload.projectID)
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }
}
