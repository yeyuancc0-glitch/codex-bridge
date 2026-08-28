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
  let agentRegistry: ServiceAgentRegistry?
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
    agentRegistry: ServiceAgentRegistry? = nil,
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
    self.agentRegistry = agentRegistry
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
}
