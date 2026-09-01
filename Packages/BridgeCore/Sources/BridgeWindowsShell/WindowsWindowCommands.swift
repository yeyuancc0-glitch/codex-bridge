#if os(Windows)
  import BridgeIPC
  import Foundation

  enum MainWindowCommand: Equatable {
    case selectPage(index: Int)
    case refreshCurrentPage
    case openRecentTask(index: Int)
    case browserBack
    case browserForward
    case browserReload
    case openChatExternally
    case refreshTasks
    case startService
    case selectTask(index: Int)
    case interruptSelectedTask
    case submitSteer(input: String)
    case showApprovals
    case selectApproval(index: Int)
    case refreshApprovals
    case resolveApproval(decision: String)
    case showProjects
    case showAgents
    case selectProject(index: Int)
    case refreshProjects
    case registerProject(name: String, path: String)
    case removeSelectedProject
    case saveProjectPolicy(read: String, write: String, network: String)
    case selectAgentProvider(index: Int)
    case selectAgentInstallation(index: Int)
    case refreshAgents
    case registerAgent(providerID: String, executablePath: String, configurationPath: String)
    case enableSelectedAgent
    case disableSelectedAgent
    case reprobeSelectedAgent(acceptReplacement: Bool)
    case removeSelectedAgent
    case showWorkspace
    case selectWorkspaceProject(index: Int)
    case selectWorkspaceCommand(index: Int)
    case selectWorkspaceSkill(index: Int)
    case refreshWorkspace
    case setWorkspaceMode(mode: String)
    case saveWorkspaceCommand(
      name: String,
      executable: String,
      arguments: String,
      workingDirectory: String,
      requiresNetwork: Bool,
      risk: String
    )
    case removeSelectedWorkspaceCommand
    case showAgentDefaults
    case selectDefaultProvider(index: Int)
    case selectDefaultInstallation(index: Int)
    case refreshAgentDefaults
    case refreshAgentModels
    case saveAgentDefaults(model: String, permissionMode: String, effort: String)
    case showLogs
    case refreshLogs
    case selectLog(index: Int)
    case showSettings
    case refreshSettings
    case saveSettingsPreferences(preferences: IPCModelPreferences)
    case saveSettingsInstructions(text: String)
    case setSettingsDirectApprovalMode(mode: String)
    case setSettingsTaskStartApprovalMode(mode: String)
  }
#endif
