import BridgeMCP
import SwiftUI

struct ProjectWorkspaceEditor: View {
  @ObservedObject var model: BridgeServiceAppModel
  let project: MCPProjectSummary
  @State private var draftMode: String
  @State private var drafts: [BridgeWorkspaceCommandDraft]
  @State private var blacklistDrafts: [BridgeBlacklistDraft]
  @State private var showSavedFeedback = false
  @State private var modeChanged = false

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
  }

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("MCP Direct 命令", systemImage: "terminal")
            .font(.subheadline.weight(.semibold))
          Spacer()
          if showSavedFeedback {
            HStack(spacing: 4) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("已保存生效")
                .font(.caption)
                .foregroundStyle(.green)
            }
            .transition(.opacity)
          }
        }

        Text(
          "默认仍由 Codex 执行项目任务。这里配置的是用户在 MCP 客户端中明确要求\u{201C}直接执行\u{201D}时，客户端可以使用的本地命令。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Divider()

        Picker("Direct 命令模式", selection: $draftMode) {
          Text("禁止").tag("denied")
          Text("安全模式").tag("safe")
          Text("完全模式").tag("full")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)

        Text(modeDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

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

        HStack {
          Button("+ 添加命令") {
            drafts.append(BridgeWorkspaceCommandDraft())
          }
          .buttonStyle(.bordered)

          Spacer()

          Button("保存命令配置") {
            model.saveProjectCommands(
              projectID: project.projectID,
              drafts: drafts,
              commandBlacklist: blacklistDrafts.map { $0.toIPCRule() }
            )
            withAnimation(.easeInOut(duration: 0.2)) {
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
          .disabled(!hasCommandChanges)

          if modeChanged {
            Button("保存命令模式") {
              model.setProjectCommandMode(projectID: project.projectID, mode: draftMode)
              modeChanged = false
              withAnimation(.easeInOut(duration: 0.2)) {
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
        }
      }
      .onAppear {
        loadDetail()
      }
      .onChange(of: model.projectDetails[project.projectID]) {
        loadDetail()
      }
      .onChange(of: draftMode) {
        modeChanged = true
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
    guard let detail = model.projectDetails[project.projectID] else { return }
    if !modeChanged {
      draftMode = detail.directWorkspace?.commandMode ?? "safe"
    }
    if !hasCommandChanges {
      let existing = detail.directWorkspace?.commands ?? []
      drafts = existing.map(BridgeWorkspaceCommandDraft.init)
      let existingBlacklist = detail.directWorkspace?.commandBlacklist ?? []
      blacklistDrafts = existingBlacklist.map(BridgeBlacklistDraft.init)
    }
  }

  private var hasCommandChanges: Bool {
    guard let detail = model.projectDetails[project.projectID] else { return true }
    let existing = detail.directWorkspace?.commands ?? []
    guard existing.count == drafts.count else { return true }
    return zip(existing, drafts).contains { command, draft in
      command.name != draft.name
        || command.executable != draft.executable
        || command.arguments
          != draft.arguments.split(separator: "\n")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        || command.workingDirectory
          != (draft.workingDirectory.isEmpty ? nil : draft.workingDirectory)
        || command.requiresNetwork != draft.requiresNetwork
        || command.risk != draft.risk
    }
  }
}
