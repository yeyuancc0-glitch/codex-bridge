#if os(Windows)
  import BridgeIPC
  import Foundation

  enum MainWindowCommand: Equatable {
    case selectPage(index: Int)
    case selectProjectsSection(index: Int)
    case selectConnectionsSection(index: Int)
    case selectSettingsSection(index: Int)
    case refreshCurrentPage
    case openRecentTask(index: Int)
    case browserBack
    case browserForward
    case browserReload
    case openChatExternally
    case refreshTasks
    case startService
    case selectTask(index: Int)
    case selectWorkbenchProject(index: Int)
    case selectWorkbenchPermission(index: Int)
    case selectWorkbenchItem(index: Int)
    case interruptSelectedTask
    case stopSelectedTask
    case deleteSelectedTask
    case submitSteer(input: String)
    case showApprovals
    case selectApproval(index: Int)
    case refreshApprovals
    case resolveApproval(decision: String)
    case showProjects
    case showAgents
    case selectMCPClient(index: Int)
    case refreshMCPConnections
    case toggleSelectedMCPClient
    case setSelectedMCPExposure(index: Int)
    case copySelectedMCPConfiguration
    case rotateSelectedMCPCredential
    case rotateLocalMCPEndpoint
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
    case selectWorkspaceThread(index: Int)
    case selectWorkspaceBlacklist(index: Int)
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
    case saveWorkspaceBlacklist(executable: String, pattern: String)
    case removeSelectedWorkspaceBlacklist
    case showAgentDefaults
    case selectDefaultProvider(index: Int)
    case selectDefaultInstallation(index: Int)
    case refreshAgentDefaults
    case refreshAgentModels
    case saveAgentDefaults(model: String, permissionMode: String, effort: String)
    case showLogs
    case refreshLogs
    case selectLog(index: Int)
    case setLogSearch(text: String)
    case setLogProjectFilter(index: Int)
    case setLogKindFilter(index: Int)
    case copyLogs
    case showSettings
    case refreshSettings
    case saveSettingsPreferences(preferences: IPCModelPreferences)
    case saveSettingsInstructions(text: String)
    case setSettingsDirectApprovalMode(mode: String)
    case setSettingsTaskStartApprovalMode(mode: String)
  }
#endif
