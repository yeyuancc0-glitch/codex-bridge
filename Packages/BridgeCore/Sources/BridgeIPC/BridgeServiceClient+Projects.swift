import BridgeMCP

extension BridgeServiceClient {
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

  public func projectCommands(projectID: String) async throws -> MCPProjectDetail {
    try await call(
      operation: .getProjectCommands,
      payload: IPCProjectCommandsRequest(projectID: projectID)
    )
  }

  public func updateProjectCommands(
    projectID: String,
    commands: [IPCWorkspaceCommand],
    commandBlacklist: [IPCBlacklistRule] = []
  ) async throws -> MCPProjectDetail {
    try await call(
      operation: .updateProjectCommands,
      payload: IPCProjectCommandsUpdateRequest(
        projectID: projectID,
        commands: commands,
        commandBlacklist: commandBlacklist
      )
    )
  }

  public func setProjectCommandMode(
    projectID: String,
    commandMode: String
  ) async throws -> MCPProjectDetail {
    try await call(
      operation: .setProjectCommandMode,
      payload: IPCProjectCommandModeUpdateRequest(projectID: projectID, commandMode: commandMode)
    )
  }

  public func setWorkbenchProject(projectID: String?) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .setWorkbenchProject,
      payload: IPCWorkbenchProjectRequest(projectID: projectID)
    )
  }
}
