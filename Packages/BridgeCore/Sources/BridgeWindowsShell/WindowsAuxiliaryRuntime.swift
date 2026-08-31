#if os(Windows)
  import BridgeServiceAppCore
  import Foundation

  @MainActor
  final class WindowsAuxiliaryRuntime {
    let workspace: WindowsWorkspaceModel
    let agentDefaults: WindowsAgentDefaultsModel
    let logs: WindowsLogModel
    let settings: WindowsSettingsModel

    private var lastWorkspaceDisplay: WindowsWorkspaceDisplay?
    private var lastAgentDefaultsDisplay: WindowsAgentDefaultsDisplay?
    private var lastLogDisplay: WindowsLogDisplay?
    private var lastSettingsDisplay: WindowsSettingsDisplay?

    init(client: any BridgeServiceClientProtocol) {
      workspace = WindowsWorkspaceModel(client: client)
      agentDefaults = WindowsAgentDefaultsModel(client: client)
      logs = WindowsLogModel(client: client)
      settings = WindowsSettingsModel(client: client)
    }

    func run(_ command: MainWindowCommand) {
      switch command {
      case .showWorkspace, .selectWorkspaceProject, .selectWorkspaceCommand,
        .selectWorkspaceSkill, .refreshWorkspace, .setWorkspaceMode, .saveWorkspaceCommand,
        .removeSelectedWorkspaceCommand:
        runWorkspace(command)
      case .showAgentDefaults, .selectDefaultProvider, .selectDefaultInstallation,
        .refreshAgentDefaults, .refreshAgentModels, .saveAgentDefaults:
        runAgentDefaults(command)
      case .showLogs, .refreshLogs, .selectLog:
        runLogs(command)
      case .showSettings, .refreshSettings, .saveSettingsPreferences,
        .saveSettingsInstructions, .setSettingsDirectApprovalMode,
        .setSettingsTaskStartApprovalMode:
        runSettings(command)
      default:
        break
      }
    }

    private func runWorkspace(_ command: MainWindowCommand) {
      switch command {
      case .showWorkspace:
        WindowsWorkspaceWindow.show(owner: WindowsMainWindow.currentWindow())
        workspace.refreshDisplaySnapshot()
        applyWorkspace()
        Task { await workspace.refresh() }
      case .selectWorkspaceProject(let index):
        workspace.selectProject(at: index)
      case .selectWorkspaceCommand(let index):
        workspace.selectCommand(at: index)
      case .selectWorkspaceSkill(let index):
        workspace.selectSkill(at: index)
      case .refreshWorkspace:
        Task { await workspace.refreshSelected() }
      case .setWorkspaceMode(let mode):
        Task { await workspace.setMode(mode) }
      case .saveWorkspaceCommand(
        let name,
        let executable,
        let arguments,
        let workingDirectory,
        let requiresNetwork,
        let risk
      ):
        let draft = BridgeWorkspaceCommandDraft(
          name: name,
          executable: executable,
          arguments: arguments,
          workingDirectory: workingDirectory,
          requiresNetwork: requiresNetwork,
          risk: risk
        )
        Task { await workspace.saveCommand(draft) }
      case .removeSelectedWorkspaceCommand:
        Task { await workspace.removeSelectedCommand() }
      default:
        break
      }
    }

    private func runAgentDefaults(_ command: MainWindowCommand) {
      switch command {
      case .showAgentDefaults:
        WindowsAgentDefaultsWindow.show(owner: WindowsMainWindow.currentWindow())
        agentDefaults.refreshDisplaySnapshot()
        applyAgentDefaults()
        Task { await agentDefaults.refresh() }
      case .selectDefaultProvider(let index):
        agentDefaults.selectProvider(at: index)
        Task { await agentDefaults.refreshModels() }
      case .selectDefaultInstallation(let index):
        agentDefaults.selectInstallation(at: index)
        Task { await agentDefaults.refreshModels() }
      case .refreshAgentDefaults:
        Task { await agentDefaults.refresh() }
      case .refreshAgentModels:
        Task { await agentDefaults.refreshModels() }
      case .saveAgentDefaults(let model, let permissionMode, let effort):
        Task {
          await agentDefaults.saveDefaults(
            model: model, permissionMode: permissionMode, effort: effort)
        }
      default:
        break
      }
    }

    private func runLogs(_ command: MainWindowCommand) {
      switch command {
      case .showLogs:
        WindowsLogWindow.show(owner: WindowsMainWindow.currentWindow())
        logs.refreshDisplaySnapshot()
        applyLogs()
        Task { await logs.refresh() }
      case .refreshLogs:
        Task { await logs.refresh() }
      case .selectLog(let index):
        logs.selectItem(at: index)
      default:
        break
      }
    }

    private func runSettings(_ command: MainWindowCommand) {
      switch command {
      case .showSettings:
        WindowsSettingsWindow.show(owner: WindowsMainWindow.currentWindow())
        settings.refreshDisplaySnapshot()
        applySettings()
        Task { await settings.refresh() }
      case .refreshSettings:
        Task { await settings.refresh() }
      case .saveSettingsPreferences(let preferences):
        Task { await settings.savePreferences(preferences) }
      case .saveSettingsInstructions(let text):
        Task { await settings.saveInstructions(text) }
      case .setSettingsDirectApprovalMode(let mode):
        Task { await settings.setDirectApprovalMode(mode) }
      case .setSettingsTaskStartApprovalMode(let mode):
        Task { await settings.setTaskStartApprovalMode(mode) }
      default:
        break
      }
    }

    func applyDisplay() {
      workspace.refreshDisplaySnapshot()
      agentDefaults.refreshDisplaySnapshot()
      logs.refreshDisplaySnapshot()
      settings.refreshDisplaySnapshot()
      applyWorkspace()
      applyAgentDefaults()
      applyLogs()
      applySettings()
    }

    func shutdown() {
      WindowsWorkspaceWindow.shutdown()
      WindowsAgentDefaultsWindow.shutdown()
      WindowsLogWindow.shutdown()
      WindowsSettingsWindow.shutdown()
    }

    private func applyWorkspace() {
      let value = workspace.displayBox.current()
      guard value != lastWorkspaceDisplay else { return }
      WindowsWorkspaceWindow.apply(value)
      lastWorkspaceDisplay = value
    }

    private func applyAgentDefaults() {
      let value = agentDefaults.displayBox.current()
      guard value != lastAgentDefaultsDisplay else { return }
      WindowsAgentDefaultsWindow.apply(value)
      lastAgentDefaultsDisplay = value
    }

    private func applyLogs() {
      let value = logs.displayBox.current()
      guard value != lastLogDisplay else { return }
      WindowsLogWindow.apply(value)
      lastLogDisplay = value
    }

    private func applySettings() {
      let value = settings.displayBox.current()
      guard value != lastSettingsDisplay else { return }
      WindowsSettingsWindow.apply(value)
      lastSettingsDisplay = value
    }
  }
#endif
