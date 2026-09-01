#if os(Windows)
  import BridgeServiceAppCore
  import Foundation

  @MainActor
  final class WindowsAuxiliaryRuntime {
    let workspace: WindowsWorkspaceModel
    let agentDefaults: WindowsAgentDefaultsModel
    let logs: WindowsLogModel
    let settings: WindowsSettingsModel
    let connections: WindowsConnectionModel

    private var lastWorkspaceDisplay: WindowsWorkspaceDisplay?
    private var lastAgentDefaultsDisplay: WindowsAgentDefaultsDisplay?
    private var lastLogDisplay: WindowsLogDisplay?
    private var lastSettingsDisplay: WindowsSettingsDisplay?
    private var lastConnectionDisplay: WindowsConnectionDisplay?

    init(client: any BridgeServiceClientProtocol) {
      workspace = WindowsWorkspaceModel(client: client)
      agentDefaults = WindowsAgentDefaultsModel(client: client)
      logs = WindowsLogModel(client: client)
      settings = WindowsSettingsModel(client: client)
      connections = WindowsConnectionModel(client: client)
    }

    func run(_ command: MainWindowCommand) {
      switch command {
      case .showWorkspace, .selectWorkspaceProject, .selectWorkspaceCommand,
        .selectWorkspaceSkill, .selectWorkspaceThread, .refreshWorkspace, .setWorkspaceMode,
        .selectWorkspaceBlacklist, .saveWorkspaceCommand, .removeSelectedWorkspaceCommand,
        .saveWorkspaceBlacklist, .removeSelectedWorkspaceBlacklist:
        runWorkspace(command)
      case .showAgentDefaults, .selectDefaultProvider, .selectDefaultInstallation,
        .refreshAgentDefaults, .refreshAgentModels, .saveAgentDefaults:
        runAgentDefaults(command)
      case .showLogs, .refreshLogs, .selectLog, .setLogSearch, .setLogProjectFilter,
        .setLogKindFilter, .copyLogs:
        runLogs(command)
      case .showSettings, .refreshSettings, .saveSettingsPreferences,
        .saveSettingsInstructions, .setSettingsDirectApprovalMode,
        .setSettingsTaskStartApprovalMode:
        runSettings(command)
      case .selectMCPClient, .refreshMCPConnections, .toggleSelectedMCPClient,
        .setSelectedMCPExposure, .copySelectedMCPConfiguration,
        .rotateSelectedMCPCredential, .rotateLocalMCPEndpoint:
        runConnections(command)
      default:
        break
      }
    }

    private func runConnections(_ command: MainWindowCommand) {
      switch command {
      case .selectMCPClient(let index):
        connections.selectClient(at: index)
      case .refreshMCPConnections:
        Task { await connections.refresh() }
      case .toggleSelectedMCPClient:
        Task { await connections.toggleSelectedClient() }
      case .setSelectedMCPExposure(let index):
        Task { await connections.setSelectedExposure(at: index) }
      case .copySelectedMCPConfiguration:
        Task {
          guard let configuration = await connections.exportSelectedConfiguration() else { return }
          connections.didCopyConfiguration(
            WindowsClipboard.write(configuration, owner: WindowsMainWindow.currentWindow()))
        }
      case .rotateSelectedMCPCredential:
        Task { await connections.rotateSelectedCredential() }
      case .rotateLocalMCPEndpoint:
        Task { await connections.rotateEndpoint() }
      default:
        break
      }
    }

    private func runWorkspace(_ command: MainWindowCommand) {
      switch command {
      case .showWorkspace:
        onUI { WindowsWorkspaceWindow.show(owner: WindowsMainWindow.currentWindow()) }
        workspace.refreshDisplaySnapshot()
        applyWorkspace()
        Task { await workspace.refresh() }
      case .selectWorkspaceProject(let index):
        workspace.selectProject(at: index)
      case .selectWorkspaceCommand(let index):
        workspace.selectCommand(at: index)
      case .selectWorkspaceSkill(let index):
        workspace.selectSkill(at: index)
      case .selectWorkspaceThread(let index):
        workspace.selectThread(at: index)
      case .selectWorkspaceBlacklist(let index):
        workspace.selectBlacklist(at: index)
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
      case .saveWorkspaceBlacklist(let executable, let pattern):
        Task { await workspace.saveBlacklist(executable: executable, pattern: pattern) }
      case .removeSelectedWorkspaceBlacklist:
        Task { await workspace.removeSelectedBlacklist() }
      default:
        break
      }
    }

    private func runAgentDefaults(_ command: MainWindowCommand) {
      switch command {
      case .showAgentDefaults:
        onUI { WindowsAgentDefaultsWindow.show(owner: WindowsMainWindow.currentWindow()) }
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
        onUI { WindowsLogWindow.show(owner: WindowsMainWindow.currentWindow()) }
        logs.refreshDisplaySnapshot()
        applyLogs()
        Task { await logs.refresh() }
      case .refreshLogs:
        Task { await logs.refresh() }
      case .selectLog(let index):
        logs.selectItem(at: index)
      case .setLogSearch(let text):
        logs.setSearchText(text)
      case .setLogProjectFilter(let index):
        logs.setProjectFilter(index)
      case .setLogKindFilter(let index):
        logs.setKindFilter(index)
      case .copyLogs:
        let display = logs.displayBox.current()
        logs.didCopy(
          WindowsClipboard.write(display.copyText, owner: WindowsMainWindow.currentWindow()))
      default:
        break
      }
    }

    private func runSettings(_ command: MainWindowCommand) {
      switch command {
      case .showSettings:
        onUI { WindowsSettingsWindow.show(owner: WindowsMainWindow.currentWindow()) }
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
      connections.refreshDisplaySnapshot()
      applyWorkspace()
      applyAgentDefaults()
      applyLogs()
      applySettings()
      applyConnections()
    }

    private func applyWorkspace() {
      let value = workspace.displayBox.current()
      guard value != lastWorkspaceDisplay else { return }
      lastWorkspaceDisplay = value
      onUI { WindowsWorkspaceWindow.apply(value) }
    }

    private func applyAgentDefaults() {
      let value = agentDefaults.displayBox.current()
      guard value != lastAgentDefaultsDisplay else { return }
      lastAgentDefaultsDisplay = value
      onUI { WindowsAgentDefaultsWindow.apply(value) }
    }

    private func applyLogs() {
      let value = logs.displayBox.current()
      guard value != lastLogDisplay else { return }
      lastLogDisplay = value
      onUI { WindowsLogWindow.apply(value) }
    }

    private func applySettings() {
      let value = settings.displayBox.current()
      guard value != lastSettingsDisplay else { return }
      lastSettingsDisplay = value
      onUI { WindowsSettingsWindow.apply(value) }
    }

    private func applyConnections() {
      let value = connections.displayBox.current()
      guard value != lastConnectionDisplay else { return }
      lastConnectionDisplay = value
      onUI { WindowsConnectionWindow.apply(value) }
    }

    private func onUI(_ action: @escaping @Sendable () -> Void) {
      WindowsUIThread.shared.enqueue(action)
    }
  }
#endif
