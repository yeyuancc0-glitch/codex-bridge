#if os(Windows)
  import BridgeServiceAppCore

  extension WindowsWorkspaceModel {
    func publishDisplay() {
      let projectIndex = selectedProjectID.flatMap { id in
        projects.firstIndex { $0.projectID == id }
      }
      let commandIndex = selectedCommandID.flatMap { id in
        commands.firstIndex { $0.id == id }
      }
      let skillIndex = selectedSkillID.flatMap { id in
        skills.firstIndex { $0.id == id }
      }
      let commandItems = commands.map(DirectWorkspacePresentation.command)
      let selectedCommand = commandIndex.flatMap { commands[$0] }
      let selectedItem = commandIndex.flatMap { commandItems[$0] }
      let skillItems = skills.map(DirectWorkspacePresentation.skill)
      let selectedSkill = skillIndex.flatMap { skillItems[$0] }
      let workspaceMode = detail?.directWorkspace?.commandMode ?? "denied"
      let hasWorkspace = detail?.directWorkspace != nil
      let value = WindowsWorkspaceDisplay(
        connectionState: connectionState,
        projectRows: projects.map { "\($0.name) · \($0.projectID)" },
        selectedProjectIndex: projectIndex,
        commandRows: commandItems.map(\.rowText),
        selectedCommandIndex: commandIndex,
        commandDetailText: selectedItem?.detailText ?? "请选择命令。",
        commandName: selectedCommand?.name ?? "",
        commandExecutable: selectedCommand?.executable ?? "",
        commandArguments: selectedCommand?.arguments ?? "",
        commandWorkingDirectory: selectedCommand?.workingDirectory ?? "",
        commandRequiresNetwork: selectedCommand?.requiresNetwork ?? false,
        commandRisk: selectedCommand?.risk ?? "normal",
        commandMode: workspaceMode,
        commandModeValues: Self.modeValues,
        skillRows: skillItems.map(\.rowText),
        selectedSkillIndex: skillIndex,
        skillDetailText: selectedSkill?.detailText
          ?? "Skills 仅支持发现和详情；当前协议没有编辑接口。",
        saveCommandEnabled: connectionState == .connected && !busy && hasWorkspace,
        removeCommandEnabled: connectionState == .connected && !busy && hasWorkspace
          && selectedCommand != nil,
        saveModeEnabled: connectionState == .connected && !busy && hasWorkspace,
        statusText: statusText
      )
      displayBox.store(value)
    }
  }
#endif
