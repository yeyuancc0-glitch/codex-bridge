import BridgeCodexService
import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import BridgeSkills
import Foundation

extension BridgeServiceApplication {
  struct SelectedModel: Sendable {
    let model: String
    let effort: String
  }

  struct ModelSelections: Sendable {
    let execution: SelectedModel
    let supervisor: SelectedModel?
  }

  func readableProject(_ rawID: String) async throws -> ServiceProjectRecord {
    guard !rawID.isEmpty, rawID.utf8.count <= 128, !rawID.contains("\0") else {
      throw BridgeMCPQueryError.projectNotFound
    }
    let id = ProjectID(rawValue: rawID)
    guard let project = try await projects.project(id: id) else {
      throw BridgeMCPQueryError.projectNotFound
    }
    do {
      try project.root.validateCurrentIdentity()
    } catch {
      throw BridgeMCPQueryError.unavailable
    }
    guard project.accessPolicy.read == .allowed else {
      throw BridgeMCPQueryError.pathDenied
    }
    return project
  }

  func modelSelections(
    submission: MCPServiceTaskSubmission,
    models: [MCPModelSummary]
  ) async throws -> ModelSelections {
    guard !models.isEmpty else { throw BridgeMCPQueryError.unavailable }
    let configuredExecutionModel = try await settings.string(for: .defaultExecutionModel)
    let configuredExecutionEffort = try await settings.string(for: .defaultExecutionEffort)
    let executionModelID =
      submission.executionModel
      ?? configuredExecutionModel
      ?? models.first(where: \.isDefault)?.modelID
      ?? models[0].modelID
    let execution = try Self.select(
      modelID: executionModelID,
      effort: submission.executionEffort ?? configuredExecutionEffort,
      models: models
    )

    guard try await settings.isSupervisorEnabled() else {
      return ModelSelections(execution: execution, supervisor: nil)
    }

    let explicitSupervisor =
      submission.supervisorModel != nil
      || submission.supervisorEffort != nil
    let configuredSupervisorModel = try await settings.string(for: .defaultSupervisorModel)
    let configuredSupervisorEffort = try await settings.string(for: .defaultSupervisorEffort)
    let supervisor: SelectedModel
    if explicitSupervisor {
      guard let model = submission.supervisorModel,
        let effort = submission.supervisorEffort
      else {
        throw BridgeMCPQueryError.contractRejected
      }
      supervisor = try Self.select(modelID: model, effort: effort, models: models)
    } else if let configuredSupervisorModel {
      supervisor = try Self.select(
        modelID: configuredSupervisorModel,
        effort: configuredSupervisorEffort,
        models: models
      )
    } else {
      let recommended =
        models.first(where: { $0.modelID == "gpt-5.6-luna" })
        ?? models.first(where: \.isDefault)
        ?? models[0]
      supervisor = try Self.select(
        modelID: recommended.modelID,
        effort: configuredSupervisorEffort,
        models: models
      )
    }
    return ModelSelections(execution: execution, supervisor: supervisor)
  }

  func resolvedDefaultModelPreferences(
    models: [MCPModelSummary]
  ) async throws -> ServiceModelPreferences {
    guard !models.isEmpty else { throw BridgeMCPQueryError.unavailable }

    let configuredExecutionModel = try await settings.string(for: .defaultExecutionModel)
    let configuredExecutionEffort = try await settings.string(for: .defaultExecutionEffort)
    let executionModelID =
      configuredExecutionModel
      ?? models.first(where: \.isDefault)?.modelID
      ?? models[0].modelID
    let execution = try Self.select(
      modelID: executionModelID,
      effort: configuredExecutionEffort,
      models: models
    )

    let configuredSupervisorModel = try await settings.string(for: .defaultSupervisorModel)
    let configuredSupervisorEffort = try await settings.string(for: .defaultSupervisorEffort)
    let supervisorModelID =
      configuredSupervisorModel
      ?? models.first(where: { $0.modelID == "gpt-5.6-luna" })?.modelID
      ?? models.first(where: \.isDefault)?.modelID
      ?? models[0].modelID
    let supervisor = try Self.select(
      modelID: supervisorModelID,
      effort: configuredSupervisorEffort,
      models: models
    )

    return ServiceModelPreferences(
      executionModel: execution.model,
      executionEffort: execution.effort,
      supervisorModel: supervisor.model,
      supervisorEffort: supervisor.effort,
      accessMode: try await settings.accessMode(),
      fastModeEnabled: try await settings.isFastModeEnabled()
    )
  }

  static func select(
    modelID: String,
    effort: String?,
    models: [MCPModelSummary]
  ) throws -> SelectedModel {
    guard let model = models.first(where: { $0.modelID == modelID }) else {
      throw BridgeMCPQueryError.contractRejected
    }
    let selectedEffort =
      effort
      ?? model.defaultReasoningEffort
      ?? model.reasoningEfforts.first
    guard let selectedEffort, model.reasoningEfforts.contains(selectedEffort) else {
      throw BridgeMCPQueryError.contractRejected
    }
    return SelectedModel(model: model.modelID, effort: selectedEffort)
  }

  static func permissionMode(
    _ rawValue: String?,
    project: ServiceProjectRecord
  ) throws -> ServicePermissionMode {
    if let rawValue {
      guard let mode = ServicePermissionMode(rawValue: rawValue) else {
        throw BridgeMCPQueryError.contractRejected
      }
      if mode == .workspaceWrite, project.accessPolicy.write == .denied {
        throw BridgeMCPQueryError.contractRejected
      }
      return mode
    }
    return project.accessPolicy.write == .denied ? .readOnly : .workspaceWrite
  }

  static func prompt(_ prompt: String, acceptanceCriteria: [String]) -> String {
    guard !acceptanceCriteria.isEmpty else { return prompt }
    let lines = acceptanceCriteria.enumerated().map { index, value in
      "\(index + 1). \(value.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    return prompt + "\n\nAcceptance criteria:\n" + lines.joined(separator: "\n")
  }

  static func projectSummary(_ source: ServiceProjectRecord) -> MCPProjectSummary {
    MCPProjectSummary(
      projectID: source.id.rawValue,
      name: safe(source.name, maximum: 1_024),
      capabilities: capabilities(source.accessPolicy)
    )
  }

  static func capabilities(_ policy: ProjectAccessPolicy) -> MCPProjectCapabilities {
    MCPProjectCapabilities(
      read: policy.read.rawValue,
      write: policy.write.rawValue,
      network: policy.network.rawValue
    )
  }

  static func projectCommand(_ command: ServiceWorkspaceCommand) -> MCPProjectCommand {
    MCPProjectCommand(
      commandID: command.id,
      name: Self.safe(command.name, maximum: 256),
      executable: Self.safe(command.executable, maximum: 4_096),
      arguments: command.arguments.map { Self.safe($0, maximum: 4_096) },
      workingDirectory: command.workingDirectory.map { Self.safe($0, maximum: 1_024) },
      requiresNetwork: command.requiresNetwork,
      risk: command.risk.rawValue
    )
  }

  static func blacklistRule(_ rule: ServiceCommandBlacklistRule) -> MCPCommandBlacklistRule {
    MCPCommandBlacklistRule(
      ruleID: Self.safe(rule.id, maximum: 128),
      executable: rule.executable.map { Self.safe($0, maximum: 4_096) },
      pattern: rule.pattern.map { Self.safe($0, maximum: 4_096) }
    )
  }

  static func executionState(_ tasks: [ServiceTaskRecord]) -> String {
    if tasks.contains(where: { $0.state.status == .unknown }) { return "unknown" }
    if tasks.contains(where: {
      [.starting, .running, .waitingForCodexApproval].contains($0.state.status)
    }) {
      return "active"
    }
    if tasks.contains(where: { $0.state.status == .awaitingLocalApproval }) {
      return "pending"
    }
    return "idle"
  }

  static func supervisorState(_ tasks: [ServiceTaskRecord]) -> String {
    if tasks.contains(where: { $0.state.supervisorStatus == .degraded }) {
      return "degraded"
    }
    if tasks.contains(where: {
      [.starting, .running].contains($0.state.supervisorStatus)
    }) {
      return "active"
    }
    return "idle"
  }

  static func decodeOffset(_ cursor: String?, maximum: Int) throws -> Int {
    guard let cursor else { return 0 }
    let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "v1", let value = Int(parts[1]),
      value >= 0, value <= maximum
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return value
  }

  static func safe(_ value: String, maximum: Int) -> String {
    OutboundContentSecurity.redacted(value, maximumUTF8Bytes: maximum)
  }

  static func publicFileError(_ error: Error) -> BridgeMCPQueryError {
    if let value = error as? ProjectFileError {
      switch value {
      case .unknownProject:
        return .projectNotFound
      case .readNotAllowed, .forbiddenPath:
        return .pathDenied
      case .pathMissing:
        return .pathNotFound
      case .invalidLineRange, .invalidSearchRequest, .invalidCursor:
        return .contractRejected
      case .invalidLimits, .candidateLimitExceeded, .enumerationLimitExceeded,
        .directoryDepthExceeded, .pathLengthExceeded, .lineTooLong,
        .responseLimitExceeded, .unsafeFilesystemState:
        return .unavailable
      }
    }
    if error is PathSecurityError { return .pathDenied }
    return .unavailable
  }

  static func publicSkillError(_ error: Error) -> BridgeMCPQueryError {
    switch error {
    case SkillError.pathEscapeDetected, SkillError.sensitivePath:
      return .pathDenied
    case SkillError.documentTooLarge, SkillError.invalidEncoding, SkillError.invalidManifest,
      SkillError.invalidSkillName, SkillError.tooManySkills:
      return .contractRejected
    case SkillError.documentNotFound:
      return .skillNotFound
    case SkillError.actionNotFound:
      return .skillActionNotFound
    case SkillError.actionNotRunnable:
      return .skillActionNotRunnable
    default:
      return .unavailable
    }
  }

  static func publicStoreError(_ error: ServiceStoreError) -> BridgeMCPQueryError {
    switch error {
    case .unknownProject:
      return .projectNotFound
    case .unknownTask:
      return .taskNotFound
    case .idempotencyConflict, .duplicateTask:
      return .idempotencyConflict
    case .activeWriteTaskExists:
      return .busy
    case .invalidArgument, .invalidTaskTransition, .immutableTaskChanged:
      return .contractRejected
    case .corruptSchema, .corruptRecord, .unsupportedSchemaVersion,
      .duplicateProject, .duplicateProjectRoot, .storageFailure:
      return .unavailable
    }
  }

  static func publicExecutionError(_ error: Error) -> BridgeMCPQueryError {
    guard let value = error as? ExecutionServiceError else { return .unavailable }
    switch value {
    case .bindingMismatch, .threadMismatch:
      return .turnMismatch
    case .sessionLimitReached, .activeSession:
      return .busy
    case .invalidRequest, .projectPermissionDenied, .approvalExceedsPolicy, .modelUnavailable,
      .effortUnavailable, .serviceTierUnavailable:
      return .contractRejected
    case .projectUnavailable:
      return .projectNotFound
    case .threadUnavailable:
      return .threadNotFound
    case .sessionUnavailable, .sessionEnded, .projectIdentityChanged, .turnUnavailable,
      .turnStartTimedOut, .approvalUnavailable, .protocolViolation, .processUnavailable:
      return .unavailable
    case .conversationPersistenceFailed:
      return .unavailable
    }
  }

  static func publicWorkspaceBusyError(_ error: Error) -> BridgeMCPQueryError {
    guard let value = error as? ProjectWorkspaceBusyError else { return .unavailable }
    switch value {
    case .busy(let detail):
      return .projectBusy(detail)
    }
  }

  static func publicMutationError(_ error: Error) -> BridgeMCPQueryError {
    guard let value = error as? ProjectMutationError else { return .unavailable }
    switch value {
    case .unknownProject:
      return .projectNotFound
    case .readNotAllowed:
      return .pathDenied
    case .writeNotAllowed:
      return .writeNotAllowed
    case .forbiddenPath:
      return .pathForbidden
    case .pathMissing:
      return .pathNotFound
    case .invalidRequest, .pathExists, .contentTooLarge:
      return .contractRejected
    case .revisionConflict:
      return .fileRevisionConflict
    case .revisionConflictWithContext(let relativePath, let currentSHA256, let boundedDiff):
      return .revisionConflict(
        RevisionConflictDetail(
          relativePath: relativePath,
          currentSHA256: currentSHA256,
          changedSinceRevision: true,
          removedLines: boundedDiff.removedLines,
          addedLines: boundedDiff.addedLines,
          truncated: boundedDiff.truncated,
          byteCount: boundedDiff.byteCount
        )
      )
    case .pathChanged, .unsupportedHardLink, .unsafeFilesystemState:
      return .pathChanged
    case .binaryContent:
      return .pathDenied
    case .invalidPatch:
      return .invalidPatch
    case .partialCommit:
      return .unavailable
    case .durabilityUncertain:
      return .durabilityUncertain
    case .notGitRepository:
      return .notGitRepository
    }
  }

  static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
  }
}
