import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  func prepareTaskSubmission(
    _ submission: MCPServiceTaskSubmission,
    sourceClientID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> PreparedTaskSubmission {
    let projectID = try await submissionProjectID(explicit: submission.projectID)
    let project = try await readableProject(projectID)
    let workbenchPermissionMode = try await workbenchDefaultPermissionMode(
      sourceClientID: sourceClientID
    )
    if let providerRaw = submission.providerID {
      return try await prepareAgentSubmission(
        submission,
        providerRaw: providerRaw,
        project: project,
        sourceClientID: sourceClientID,
        workbenchPermissionMode: workbenchPermissionMode,
        deadline: deadline
      )
    }
    let models = try await catalog.listModels(deadline: deadline).models
    let selections = try await modelSelections(submission: submission, models: models)
    let requestedPermissionMode = try Self.permissionModeRequest(
      submission.permissionMode,
      override: submission.permissionModeOverride,
      requireWorkspaceWriteOverride: workbenchPermissionMode != nil
    )
    let permission = try Self.permissionMode(
      requestedPermissionMode,
      project: project,
      defaultMode: workbenchPermissionMode
    )
    let accessMode = try await settings.accessMode()
    let fastMode =
      try await settings.isFastModeEnabled()
      && models.first(where: { $0.modelID == selections.execution.model })?
        .supportsFastMode == true
    guard !submission.networkAccess || project.accessPolicy.network != .denied else {
      throw BridgeMCPQueryError.contractRejected
    }
    let taskPrompt = try await taskPrompt(for: submission, project: project, deadline: deadline)
    return PreparedTaskSubmission(
      projectID: project.id,
      request: ServiceTaskRequest(
        projectID: project.id,
        source: .mcpClient,
        sourceClientID: sourceClientID,
        clientRequestID: submission.clientRequestID,
        prompt: taskPrompt,
        requestedThreadID: submission.threadID,
        executionModel: selections.execution.model,
        executionEffort: selections.execution.effort,
        supervisorModel: selections.supervisor?.model,
        supervisorEffort: selections.supervisor?.effort,
        permissionMode: permission,
        networkAllowed: submission.networkAccess,
        accessMode: accessMode,
        fastMode: fastMode
      )
    )
  }

  private func workbenchDefaultPermissionMode(
    sourceClientID: String
  ) async throws -> ServicePermissionMode? {
    guard
      sourceClientID == MCPClientID.chatGPT.rawValue
        || sourceClientID == MCPClientID.qwenStudio.rawValue
    else {
      return nil
    }
    return try await settings.workbenchPermissionMode()
  }

  private func submissionProjectID(explicit: String?) async throws -> String {
    if let explicit { return explicit }
    if let selected = try await settings.string(for: .workbenchProjectID), !selected.isEmpty,
      selected.utf8.count <= 128, !selected.contains("\0"),
      try await projects.project(id: ProjectID(rawValue: selected)) != nil
    {
      return selected
    }
    guard let fallback = Self.sortedProjects(try await projects.projects()).first else {
      throw BridgeMCPQueryError.projectNotFound
    }
    return fallback.id.rawValue
  }

  func taskPrompt(
    for submission: MCPServiceTaskSubmission,
    project: ServiceProjectRecord,
    deadline: ContinuousClock.Instant
  ) async throws -> String {
    var prompt = Self.prompt(
      submission.prompt,
      acceptanceCriteria: submission.acceptanceCriteria
    )
    if let skillName = submission.skillName {
      let skill = try await serviceReadSkill(
        skillName: skillName,
        projectID: project.id.rawValue,
        subpath: "SKILL.md",
        deadline: deadline
      )
      let instructions = String(skill.content.prefix(8 * 1_024))
      prompt =
        "Skill instructions for \(skill.name):\n\n\(instructions)\n\nUser task:\n\(prompt)"
    }
    guard prompt.utf8.count <= 32 * 1_024 else {
      throw BridgeMCPQueryError.contractRejected
    }
    return prompt
  }
}
