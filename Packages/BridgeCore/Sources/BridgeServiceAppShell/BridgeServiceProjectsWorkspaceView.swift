import BridgeMCP
import SwiftUI
import BridgeServiceAppCore

struct ProjectWorkspaceEditor: View {
  @ObservedObject var model: BridgeServiceAppModel
  let project: MCPProjectSummary
  @State private var draftMode: String
  @State private var drafts: [BridgeWorkspaceCommandDraft]
  @State private var blacklistDrafts: [BridgeBlacklistDraft]
  @State private var showSavedFeedback = false
  @State private var loadedState: ProjectWorkspaceDraftState?

  init(model: BridgeServiceAppModel, project: MCPProjectSummary) {
    self.model = model
    self.project = project
    let detail = model.projectDetails[project.projectID]
    _draftMode = State(initialValue: detail?.directWorkspace?.commandMode ?? "safe")
    _drafts = State(
      initialValue: detail?.directWorkspace?.commands.map(BridgeWorkspaceCommandDraft.init) ?? []
    )
    _blacklistDrafts = State(
      initialValue: detail?.directWorkspace?.commandBlacklist.map(BridgeBlacklistDraft.init) ?? []
    )
    _loadedState = State(
      initialValue: detail?.directWorkspace.map(ProjectWorkspaceDraftState.init)
    )
  }

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("MCP Direct 命令与安全模式", systemImage: "terminal")
            .font(.subheadline.weight(.semibold))
          Spacer()
          SaveFeedbackBadge(
            showSaved: showSavedFeedback,
            isModified: hasCommandChanges || modeChanged,
            savedText: "命令配置已保存生效",
            unmodifiedText: "已是最新生效状态"
          )
        }

        Text(
          "默认仍由 Codex 执行项目任务。这里配置的是用户在 MCP 客户端中明确要求\u{201C}直接执行\u{201D}时，客户端可以使用的本地命令。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Divider()

        VStack(alignment: .leading, spacing: 6) {
          Text("Direct 命令执行策略")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          Picker("Direct 命令模式", selection: $draftMode) {
            Text("禁止直接执行").tag("denied")
            Text("安全模式 (推荐)").tag("safe")
            Text("完全模式 (无白名单限制)").tag("full")
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 480)

          Text(modeDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }

        Divider()

        if draftMode == "safe" {
          Text(
            "安全模式仅放行内置安全命令与你添加的允许命令；黑名单规则在两种模式下都生效。"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        allowedCommandsList

        Divider()

        blacklistSection

        Divider()

        HStack(spacing: 12) {
          Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              drafts.append(BridgeWorkspaceCommandDraft())
            }
          } label: {
            Label("添加允许命令", systemImage: "plus")
          }
          .buttonStyle(.bordered)

          Spacer()

          if modeChanged {
            Button("保存命令模式") {
              model.setProjectCommandMode(projectID: project.projectID, mode: draftMode)
              withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                showSavedFeedback = true
              }
              Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.easeInOut(duration: 0.3)) {
                  showSavedFeedback = false
                }
              }
            }
            .buttonStyle(.borderedProminent)
          }

          Button {
            if modeChanged {
              model.setProjectCommandMode(projectID: project.projectID, mode: draftMode)
            }
            model.saveProjectCommands(
              projectID: project.projectID,
              drafts: drafts,
              commandBlacklist: blacklistDrafts.map { $0.toIPCRule() }
            )
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              showSavedFeedback = true
            }
            Task {
              try? await Task.sleep(for: .seconds(2.5))
              withAnimation(.easeInOut(duration: 0.3)) {
                showSavedFeedback = false
              }
            }
          } label: {
            HStack(spacing: 6) {
              if showSavedFeedback {
                Image(systemName: "checkmark")
              }
              Text("保存命令配置")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!hasCommandChanges && !modeChanged)
        }
      }
      .onAppear {
        loadDetail()
      }
      .onChange(of: model.projectDetails[project.projectID]) {
        loadDetail()
      }
    }
  }

  private var modeDescription: String {
    switch draftMode {
    case "denied":
      return "禁止 MCP 客户端直接执行任何命令。"
    case "full":
      return "完全模式放行所有命令，不再检查白名单。"
    default:
      return "安全模式仅放行内置安全命令与允许命令列表中的命令。"
    }
  }

  private var blacklistSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("黑名单（禁止执行，两种模式均生效）", systemImage: "shield.slash")
        .font(.caption.weight(.semibold))
      if blacklistDrafts.isEmpty {
        Text("可按可执行文件或参数包含的子串禁止命令，例如 executable=rm 或 pattern=-rf。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(blacklistDrafts) { draft in
          BlacklistRow(draft: binding(for: draft)) {
            blacklistDrafts.removeAll { $0.id == draft.id }
          }
        }
      }
      Button("+ 添加黑名单规则") {
        blacklistDrafts.append(BridgeBlacklistDraft())
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  private var allowedCommandsList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("允许的命令（安全模式下可用）", systemImage: "checkmark.shield")
        .font(.caption.weight(.semibold))
      if drafts.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "command")
            .foregroundStyle(.secondary)
          Text(
            "内置安全命令包括 git status/diff/log、ls、pwd、find、swift test/build、xcodebuild 等。在这里添加额外允许的命令；参数为可选前缀。"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      } else {
        ForEach(drafts) { draft in
          ProjectCommandRow(draft: binding(for: draft)) {
            drafts.removeAll { $0.id == draft.id }
          }
        }
      }
    }
  }

  private func binding(for draft: BridgeWorkspaceCommandDraft) -> Binding<
    BridgeWorkspaceCommandDraft
  > {
    Binding(
      get: { drafts.first(where: { $0.id == draft.id }) ?? draft },
      set: { newValue in
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
          drafts[index] = newValue
        }
      }
    )
  }

  private func binding(for draft: BridgeBlacklistDraft) -> Binding<BridgeBlacklistDraft> {
    Binding(
      get: { blacklistDrafts.first(where: { $0.id == draft.id }) ?? draft },
      set: { newValue in
        if let index = blacklistDrafts.firstIndex(where: { $0.id == draft.id }) {
          blacklistDrafts[index] = newValue
        }
      }
    )
  }

  private func loadDetail() {
    guard let workspace = model.projectDetails[project.projectID]?.directWorkspace else { return }
    let incoming = ProjectWorkspaceDraftState(workspace: workspace)
    let current = draftState
    guard loadedState == nil || current == loadedState || current == incoming else { return }
    draftMode = workspace.commandMode
    drafts = workspace.commands.map(BridgeWorkspaceCommandDraft.init)
    blacklistDrafts = workspace.commandBlacklist.map(BridgeBlacklistDraft.init)
    loadedState = incoming
  }

  private var hasCommandChanges: Bool {
    guard let loadedState else { return false }
    return draftState != loadedState
  }

  private var modeChanged: Bool {
    guard let loadedState else { return false }
    return draftMode != loadedState.commandMode
  }

  private var draftState: ProjectWorkspaceDraftState {
    ProjectWorkspaceDraftState(
      commandMode: draftMode,
      commands: drafts,
      commandBlacklist: blacklistDrafts
    )
  }
}
