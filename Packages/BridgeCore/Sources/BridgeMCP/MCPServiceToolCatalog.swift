import MCP

public enum MCPServiceToolName: String, CaseIterable, Sendable {
  case bridgeStatus = "bridge_status"
  case listProjects = "list_projects"
  case getProject = "get_project"
  case searchProjectFiles = "search_project_files"
  case readProjectFile = "read_project_file"
  case listThreads = "list_threads"
  case readThread = "read_thread"
  case listModels = "list_models"
  case listSkills = "list_skills"
  case readSkill = "read_skill"
  case runSkillAction = "run_skill_action"
  case getTask = "get_task"
  case submitTask = "submit_task"
  case steerTask = "steer_task"
  case interruptTask = "interrupt_task"
  case getProjectChanges = "get_project_changes"
  case listProjectCommands = "list_project_commands"
  case directWriteProjectFile = "direct_write_project_file"
  case directEditProjectFile = "direct_edit_project_file"
  case directApplyProjectPatch = "direct_apply_project_patch"
  case directManageProjectPath = "direct_manage_project_path"
  case directExecCommand = "direct_exec_project_command"
  case directReadCommand = "direct_read_command"
  case directWriteStdin = "direct_write_stdin"
  case directInterruptCommand = "direct_interrupt_command"
  case directGitCommit = "direct_git_commit"
}

enum MCPServiceToolRoute: Sendable {
  case readOnly
  case task
  case direct
}

struct MCPServiceToolContract: Sendable {
  let name: MCPServiceToolName
  let definition: Tool
  let minimumExposure: MCPServiceExposureMode
  let route: MCPServiceToolRoute

  func isExposed(in mode: MCPServiceExposureMode) -> Bool {
    minimumExposure == .readOnly || mode == .full
  }
}

public struct MCPServiceToolCatalog: Sendable {
  public let definitions: [Tool]

  public init(exposureMode: MCPServiceExposureMode) {
    definitions = Self.contracts
      .filter { $0.isExposed(in: exposureMode) }
      .map(\.definition)
  }

  static func contract(named rawName: String) -> MCPServiceToolContract? {
    contractsByName[rawName]
  }

  private static let contractsByName: [String: MCPServiceToolContract] = {
    let pairs = contracts.map { ($0.name.rawValue, $0) }
    precondition(Set(pairs.map(\.0)).count == pairs.count)
    precondition(pairs.allSatisfy { $0.0 == $0.1.definition.name })
    return Dictionary(uniqueKeysWithValues: pairs)
  }()

  private static let contracts: [MCPServiceToolContract] = [
    contract(.bridgeStatus, bridgeStatus, exposure: .readOnly, route: .readOnly),
    contract(.listProjects, listProjects, exposure: .readOnly, route: .readOnly),
    contract(.getProject, getProject, exposure: .readOnly, route: .readOnly),
    contract(.searchProjectFiles, searchProjectFiles, exposure: .readOnly, route: .readOnly),
    contract(.readProjectFile, readProjectFile, exposure: .readOnly, route: .readOnly),
    contract(.listThreads, listThreads, exposure: .readOnly, route: .readOnly),
    contract(.readThread, readThread, exposure: .readOnly, route: .readOnly),
    contract(.listModels, listModels, exposure: .readOnly, route: .readOnly),
    contract(.listSkills, listSkills, exposure: .readOnly, route: .readOnly),
    contract(.readSkill, readSkill, exposure: .readOnly, route: .readOnly),
    contract(.getTask, getTask, exposure: .readOnly, route: .task),
    contract(.getProjectChanges, getProjectChanges, exposure: .readOnly, route: .readOnly),
    contract(.listProjectCommands, listProjectCommands, exposure: .readOnly, route: .readOnly),
    contract(.submitTask, submitTask, exposure: .full, route: .task),
    contract(.runSkillAction, runSkillAction, exposure: .full, route: .task),
    contract(.steerTask, steerTask, exposure: .full, route: .task),
    contract(.interruptTask, interruptTask, exposure: .full, route: .task),
    contract(.directWriteProjectFile, directWriteProjectFile, exposure: .full, route: .direct),
    contract(.directEditProjectFile, directEditProjectFile, exposure: .full, route: .direct),
    contract(.directApplyProjectPatch, directApplyProjectPatch, exposure: .full, route: .direct),
    contract(.directManageProjectPath, directManageProjectPath, exposure: .full, route: .direct),
    contract(.directExecCommand, directExecProjectCommand, exposure: .full, route: .direct),
    contract(.directReadCommand, directReadCommand, exposure: .full, route: .direct),
    contract(.directWriteStdin, directWriteStdin, exposure: .full, route: .direct),
    contract(.directInterruptCommand, directInterruptCommand, exposure: .full, route: .direct),
    contract(.directGitCommit, directGitCommit, exposure: .full, route: .direct),
  ]

  private static func contract(
    _ name: MCPServiceToolName,
    _ definition: Tool,
    exposure: MCPServiceExposureMode,
    route: MCPServiceToolRoute
  ) -> MCPServiceToolContract {
    MCPServiceToolContract(
      name: name,
      definition: definition,
      minimumExposure: exposure,
      route: route
    )
  }
}
