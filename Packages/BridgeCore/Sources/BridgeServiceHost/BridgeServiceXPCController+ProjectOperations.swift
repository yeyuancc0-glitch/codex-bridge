import BridgeDomain
import BridgeIPC
import BridgeProjects
import BridgeServiceCore
import Foundation

extension BridgeServiceXPCController {
  func handleListProjects(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let projects = try await composition.application.serviceManagedProjects(
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCProjectListResponse(projects: projects)
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
    let detail = try await composition.application.serviceRegisterManagedProject(
      name: payload.name,
      rootURL: try Self.absoluteDirectoryURL(payload.absolutePath),
      accessPolicy: policy,
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
    let detail = try await composition.application.serviceUpdateManagedProjectPolicy(
      projectID: payload.projectID,
      policy: try Self.projectPolicy(
        read: payload.readPermission,
        write: payload.writePermission,
        network: payload.networkPermission
      ),
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
    let detail = try await composition.application.serviceManagedProject(
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
    let updatedCommands = try await composition.application.serviceUpdateManagedProjectCommands(
      projectID: payload.projectID,
      commands: try Self.workspaceCommands(payload.commands),
      blacklist: try Self.blacklistRules(payload.commandBlacklist),
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
    let updatedMode = try await composition.application.serviceSetManagedProjectCommandMode(
      projectID: payload.projectID,
      mode: mode,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: updatedMode
    )
  }

  func handleSetWorkbenchProject(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCWorkbenchProjectRequest.self,
      from: request
    )
    try await composition.application.serviceSetWorkbenchProjectID(
      payload.projectID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  func handleRemoveProject(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCProjectIDRequest.self,
      from: request
    )
    try await composition.application.serviceRemoveManagedProject(
      projectID: payload.projectID,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }
}
