import BridgeCodexService
import BridgeDirectCommand
import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import BridgeSkills
import Foundation

public struct ServiceModelCatalog: Equatable, Sendable {
  public let models: MCPModelList
  public let preferences: ServiceModelPreferences

  public init(models: MCPModelList, preferences: ServiceModelPreferences) {
    self.models = models
    self.preferences = preferences
  }
}

public actor BridgeServiceApplication: BridgeMCPServiceAPI {
  let appVersion: String
  let projects: ServiceProjectService
  let tasks: ServiceTaskManager
  let settings: ServiceSettings
  let coordinator: ServiceExecutionCoordinator
  let catalog: ServiceCodexCatalog
  let files: RestrictedProjectFileService
  let mutations: RestrictedProjectMutationService
  let runtimeStatus: ServiceRuntimeStatus
  let workspaceGate: ServiceWorkspaceMutationGate
  public let commandPolicy: DirectCommandPolicy
  public let directCommands: DirectCommandSessionManager
  public let approvals: DirectActionApprovalCenter
  let skillScanner: SkillScanner
  public let iso8601 = ISO8601DateFormatter()

  public init(
    appVersion: String,
    projects: ServiceProjectService,
    tasks: ServiceTaskManager,
    settings: ServiceSettings,
    coordinator: ServiceExecutionCoordinator,
    catalog: ServiceCodexCatalog,
    runtimeStatus: ServiceRuntimeStatus,
    files: RestrictedProjectFileService? = nil,
    mutations: RestrictedProjectMutationService? = nil,
    workspaceGate: ServiceWorkspaceMutationGate? = nil,
    commandPolicy: DirectCommandPolicy = DirectCommandPolicy(),
    directCommands: DirectCommandSessionManager = DirectCommandSessionManager(),
    approvals: DirectActionApprovalCenter = DirectActionApprovalCenter(),
    skillScanner: SkillScanner = SkillScanner()
  ) {
    precondition(!appVersion.isEmpty)
    self.appVersion = appVersion
    self.projects = projects
    self.tasks = tasks
    self.settings = settings
    self.coordinator = coordinator
    self.catalog = catalog
    self.runtimeStatus = runtimeStatus
    let repository = ServiceProjectRepositoryAdapter(projects: projects)
    self.files =
      files
      ?? RestrictedProjectFileService(repository: repository)
    self.mutations =
      mutations
      ?? RestrictedProjectMutationService(repository: repository)
    self.workspaceGate = workspaceGate ?? ServiceWorkspaceMutationGate()
    self.commandPolicy = commandPolicy
    self.directCommands = directCommands
    self.approvals = approvals
    self.skillScanner = skillScanner
  }

  public func serviceStatus(
    deadline: ContinuousClock.Instant
  ) async throws -> BridgeStatusSnapshot {
    try Self.checkDeadline(deadline)
    let taskList = try await tasks.tasks(limit: 500)
    let runtime = await runtimeStatus.current()
    let codexApprovals = await coordinator.pendingApprovals().count
    let taskStartApprovals = taskList.filter {
      $0.state.status == .awaitingLocalApproval
        && $0.requiresLocalStartApproval
    }.count
    return BridgeStatusSnapshot(
      appVersion: appVersion,
      mcpState: runtime.mcpState,
      tunnelState: runtime.tunnelState,
      codexVersion: runtime.codexVersion,
      loginMode: runtime.loginMode,
      executionState: Self.executionState(taskList),
      supervisorState: Self.supervisorState(taskList),
      degradations: runtime.degradations,
      pendingApprovalCount: codexApprovals + taskStartApprovals
    )
  }

  public func serviceCustomInstructions(
    deadline: ContinuousClock.Instant
  ) async throws -> String {
    try Self.checkDeadline(deadline)
    return try await settings.customInstructions()
  }

  public func setServiceCustomInstructions(
    _ instructions: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setCustomInstructions(instructions)
  }

  public func serviceProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    try Self.checkDeadline(deadline)
    guard (1...100).contains(limit) else { throw BridgeMCPQueryError.contractRejected }
    let all = try await projects.projects()
    let visible = Self.sortedProjects(all.filter { $0.accessPolicy.read == .allowed })
    let offset = try Self.decodeOffset(cursor, maximum: visible.count)
    let end = min(offset + limit, visible.count)
    let page = visible[offset..<end].map(Self.projectSummary)
    return MCPProjectPage(
      projects: Array(page),
      nextCursor: end < visible.count ? "v1.\(end)" : nil
    )
  }

  public func serviceManagedProjects(
    deadline: ContinuousClock.Instant
  ) async throws -> [MCPProjectSummary] {
    try Self.checkDeadline(deadline)
    return Self.sortedProjects(try await projects.projects()).map(Self.projectSummary)
  }

  public func serviceProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(projectID)
    return Self.projectDetail(project)
  }

  public func serviceManagedProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    try Self.checkDeadline(deadline)
    return Self.projectDetail(try await managedProject(projectID))
  }

  public func serviceProjectCommands(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectCommands {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(projectID)
    return MCPProjectCommands(
      commandMode: project.directCommandMode.rawValue,
      builtInCommands: builtInCommands(),
      commands: project.workspaceCommands.map(Self.projectCommand)
    )
  }

  private func builtInCommands() -> [MCPBuiltInCommand] {
    commandPolicy.effectiveSafeCommandRules.map { rule in
      return MCPBuiltInCommand(
        executable: rule.executable,
        argumentsPrefix: rule.argumentsPrefix,
        requiresNetwork: rule.requiresNetwork
      )
    }
  }

  public func serviceSearchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage {
    try Self.checkDeadline(deadline)
    do {
      let result = try await files.search(
        ProjectFileSearchRequest(
          projectID: ProjectID(rawValue: projectID),
          query: query,
          relativeDirectory: relativeDirectory,
          caseSensitive: caseSensitive,
          limit: limit,
          cursor: cursor
        )
      )
      return MCPProjectFileSearchPage(
        matches: result.matches.map {
          MCPProjectFileSearchMatch(
            relativePath: $0.relativePath,
            lineNumber: $0.lineNumber,
            preview: $0.preview,
            redacted: $0.redacted
          )
        },
        nextCursor: result.nextCursor,
        skippedFileCount: result.skippedFileCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.publicFileError(error)
    }
  }

  public func serviceReadProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage {
    try Self.checkDeadline(deadline)
    do {
      let result = try await files.read(
        ProjectFileReadRequest(
          projectID: ProjectID(rawValue: projectID),
          relativePath: relativePath,
          lineRange: try FileLineRange(startLine: startLine, lineCount: lineCount)
        )
      )
      return MCPProjectFileReadPage(
        relativePath: result.relativePath,
        startLine: result.startLine,
        endLine: result.endLine,
        content: result.content,
        redactedLineCount: result.redactedLineCount,
        truncated: result.truncated,
        nextStartLine: result.nextStartLine,
        sha256: result.sha256,
        byteCount: result.byteCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.publicFileError(error)
    }
  }

  public func serviceThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    let project = try await readableProject(projectID)
    return try await catalog.listThreads(
      root: project.root.canonicalPath,
      cursor: cursor,
      limit: limit,
      search: search,
      deadline: deadline
    )
  }

  public func serviceReadThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    let project = try await readableProject(projectID)
    return try await catalog.readThread(
      root: project.root.canonicalPath,
      threadID: threadID,
      detail: detail,
      cursor: cursor,
      limit: limit,
      deadline: deadline
    )
  }

  public func serviceAppThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    let project = try await readableProject(projectID)
    let allowedThreadIDs = try await appThreadIDs(projectID: project.id)
    return try await catalog.listThreads(
      root: project.root.canonicalPath,
      cursor: cursor,
      limit: limit,
      search: search,
      including: allowedThreadIDs,
      deadline: deadline
    )
  }

  public func serviceAppReadThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    let project = try await readableProject(projectID)
    guard try await appThreadIDs(projectID: project.id).contains(threadID) else {
      throw BridgeMCPQueryError.threadNotFound
    }
    return try await catalog.readThread(
      root: project.root.canonicalPath,
      threadID: threadID,
      detail: detail,
      cursor: cursor,
      limit: limit,
      deadline: deadline
    )
  }

  private func appThreadIDs(projectID: ProjectID) async throws -> Set<String> {
    let records = try await tasks.tasks(projectID: projectID, limit: 500)
    return Set(
      records.lazy
        .filter { $0.source.isRemoteMCPOrigin }
        .compactMap { $0.state.codexThreadID }
    )
  }

  public func serviceModels(
    deadline: ContinuousClock.Instant
  ) async throws -> MCPModelList {
    try await catalog.listModels(deadline: deadline)
  }

  public func serviceListSkills(
    projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceSkillList {
    try Self.checkDeadline(deadline)
    let root: URL?
    if let projectID {
      root = URL(fileURLWithPath: try await readableProject(projectID).root.canonicalPath)
    } else {
      root = nil
    }
    do {
      let manifests = try await skillScanner.scanSkills(for: root)
      return MCPServiceSkillList(skills: manifests.map(MCPServiceSkill.init))
    } catch {
      throw Self.publicSkillError(error)
    }
  }

  public func serviceReadSkill(
    skillName: String,
    projectID: String?,
    subpath: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceSkillDocument {
    try Self.checkDeadline(deadline)
    guard skillName.utf8.count <= 128, !skillName.isEmpty else {
      throw BridgeMCPQueryError.contractRejected
    }
    let root: URL?
    if let projectID {
      root = URL(fileURLWithPath: try await readableProject(projectID).root.canonicalPath)
    } else {
      root = nil
    }
    do {
      let manifests = try await skillScanner.scanSkills(for: root)
      guard let manifest = manifests.first(where: { $0.name == skillName }) else {
        throw BridgeMCPQueryError.skillNotFound
      }
      return MCPServiceSkillDocument(
        document: try await skillScanner.readSkillDocument(manifest, subpath: subpath)
      )
    } catch let error as BridgeMCPQueryError {
      throw error
    } catch {
      throw Self.publicSkillError(error)
    }
  }

  public func serviceModelPreferences(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceModelPreferences {
    try await serviceModelCatalog(deadline: deadline).preferences
  }

  public func serviceModelCatalog(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceModelCatalog {
    try Self.checkDeadline(deadline)
    let models = try await catalog.listModels(deadline: deadline)
    let preferences = try await resolvedDefaultModelPreferences(models: models.models)
    return ServiceModelCatalog(models: models, preferences: preferences)
  }

  public func setServiceModelPreferences(
    _ preferences: ServiceModelPreferences,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    let models = try await catalog.listModels(deadline: deadline).models
    _ = try Self.select(
      modelID: preferences.executionModel,
      effort: preferences.executionEffort,
      models: models
    )
    _ = try Self.select(
      modelID: preferences.supervisorModel,
      effort: preferences.supervisorEffort,
      models: models
    )
    try Self.checkDeadline(deadline)
    try await settings.setModelPreferences(preferences)
  }

  public func setSupervisorEnabled(_ enabled: Bool) async throws {
    try await settings.setSupervisorEnabled(enabled)
  }

  public func serviceProjectChanges(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectChanges {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(projectID)
    let changes = try await mutations.changes(projectID: project.id)
    return MCPProjectChanges(
      changedFiles: changes.changedFiles,
      diff: Self.safe(changes.diff, maximum: 200 * 1_024),
      additions: changes.additions,
      deletions: changes.deletions,
      truncated: changes.truncated,
      notGitRepository: changes.notGitRepository
    )
  }

}
