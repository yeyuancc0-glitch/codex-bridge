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

public struct MCPServiceToolCatalog: Sendable {
  public let definitions: [Tool]

  public init(exposureMode: MCPServiceExposureMode) {
    var tools = [
      Self.bridgeStatus,
      Self.listProjects,
      Self.getProject,
      Self.searchProjectFiles,
      Self.readProjectFile,
      Self.listThreads,
      Self.readThread,
      Self.listModels,
      Self.listSkills,
      Self.readSkill,
      Self.getTask,
      Self.getProjectChanges,
      Self.listProjectCommands,
    ]
    if exposureMode == .full {
      tools.append(
        contentsOf: [
          Self.submitTask,
          Self.runSkillAction,
          Self.steerTask,
          Self.interruptTask,
          Self.directWriteProjectFile,
          Self.directEditProjectFile,
          Self.directApplyProjectPatch,
          Self.directManageProjectPath,
          Self.directExecProjectCommand,
          Self.directReadCommand,
          Self.directWriteStdin,
          Self.directInterruptCommand,
          Self.directGitCommit,
        ]
      )
    }
    definitions = tools
  }
}
