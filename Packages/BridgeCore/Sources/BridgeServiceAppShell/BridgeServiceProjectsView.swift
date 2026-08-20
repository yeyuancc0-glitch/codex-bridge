import AppKit
import BridgeMCP
import SwiftUI

struct BridgeServiceProjectsView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    HStack(spacing: 0) {
      projectList
        .frame(width: 280)
        .frame(maxHeight: .infinity)
      projectDetail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationTitle("项目")
    .task {
      if model.selectedProjectID == nil, let firstID = model.projects.first?.projectID {
        model.selectProject(firstID)
      }
    }
  }

  private var projectList: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("已注册项目")
            .font(.headline)
          Text("共 \(model.projects.count) 个目录")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          chooseProject()
        } label: {
          Label("添加", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
      .padding(14)

      Divider()

      if model.projects.isEmpty {
        ContentUnavailableView(
          "尚未注册项目",
          systemImage: "folder.badge.plus",
          description: Text("只有你明确添加的目录才能被 ChatGPT 和 Codex Bridge 访问。")
        )
        .frame(maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(model.projects, id: \.projectID) { project in
              let isSelected = model.selectedProjectID == project.projectID
              Button {
                model.selectProject(project.projectID)
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                  VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                      .font(.body.weight(isSelected ? .semibold : .medium))
                      .foregroundStyle(.primary)
                      .lineLimit(1)

                    Text(project.projectID)
                      .font(.system(size: 10, design: .monospaced))
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }

                  Spacer()

                  if isSelected {
                    Image(systemName: "chevron.right")
                      .font(.caption2.weight(.bold))
                      .foregroundStyle(Color.accentColor)
                  }
                }
                .padding(12)
                .background(
                  isSelected
                    ? Color.accentColor.opacity(0.12)
                    : Color(nsColor: .controlBackgroundColor)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                      isSelected
                        ? Color.accentColor.opacity(0.35)
                        : Color(nsColor: .separatorColor).opacity(0.3),
                      lineWidth: isSelected ? 1.2 : 0.8
                    )
                )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(12)
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    .overlay(
      Rectangle()
        .frame(width: 1)
        .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.35)),
      alignment: .trailing
    )
  }

  @ViewBuilder
  private var projectDetail: some View {
    if let project = selectedProject {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack(alignment: .top) {
            SectionHeader(
              project.name,
              subtitle: "项目 ID: \(project.projectID)",
              icon: "folder"
            )
            Spacer()
            Button("移除项目", role: .destructive) {
              model.removeProject(project.projectID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }

          VStack(alignment: .leading, spacing: 12) {
            Text("访问与执行权限")
              .font(.headline)
              .foregroundStyle(.secondary)

            ProjectPermissionEditor(model: model, project: project)
              .id(project.projectID)
          }

          ProjectWorkspaceEditor(model: model, project: project)
            .id(project.projectID)

          skillsSection

          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("Codex Threads")
                .font(.headline)
                .foregroundStyle(.secondary)
              Spacer()
              if let projectID = model.selectedProjectID {
                Button {
                  model.selectProject(projectID)
                } label: {
                  Label("刷新", systemImage: "arrow.clockwise")
                    .font(.caption)
                }
                .buttonStyle(.borderless)
              }
            }

            threadsSection
          }
        }
        .padding(24)
        .frame(maxWidth: 960, alignment: .leading)
      }
    } else {
      ContentUnavailableView(
        "请选择一个项目",
        systemImage: "sidebar.left",
        description: Text("从左侧列表中选择项目，以配置权限并查看绑定的 Codex Thread。")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var selectedProject: MCPProjectSummary? {
    guard let selectedProjectID = model.selectedProjectID else { return nil }
    return model.projects.first(where: { $0.projectID == selectedProjectID })
  }

  private var threadsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.threads.isEmpty {
        NativeCard {
          HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
              .foregroundStyle(.secondary)
            Text("该项目目前没有可读取的 Codex Thread。")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
        }
      } else {
        VStack(spacing: 8) {
          ForEach(model.threads, id: \.threadID) { thread in
            Button {
              model.openThread(thread.threadID)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "bubble.left.fill")
                  .font(.system(size: 14))
                  .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                  Text(thread.title ?? thread.preview ?? thread.threadID)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                  Text(thread.threadID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                StatusBadge(thread.status, tone: thread.status == "busy" ? .running : .neutral)

                Image(systemName: "chevron.right")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              .padding(12)
              .background(Color(nsColor: .controlBackgroundColor))
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
              )
            }
            .buttonStyle(.plain)
          }
        }
      }

      if let selectedThread = model.selectedThread {
        threadTranscript(selectedThread)
      }
    }
  }

  private var skillsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("已发现 Skills")
          .font(.headline)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          model.refresh()
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(model.isRefreshing)
      }
      if model.skills.isEmpty {
        NativeCard {
          Label("该项目没有发现可用 Skill", systemImage: "sparkles")
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
      } else {
        LazyVStack(spacing: 8) {
          ForEach(model.skills) { skill in
            NativeCard {
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                  .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                  HStack {
                    Text(skill.name).font(.subheadline.weight(.semibold))
                    Text(skill.scope.rawValue)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                  if !skill.description.isEmpty {
                    Text(skill.description)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(2)
                  }
                  if !skill.actions.isEmpty {
                    Text("动作：\(skill.actions.count) 个")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
                Spacer()
              }
            }
          }
        }
      }
    }
  }

  private func threadTranscript(_ page: MCPThreadReadPage) -> some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Thread 对话历史", systemImage: "bubble.left.and.text.bubble.right.fill")
            .font(.subheadline.weight(.semibold))
          Spacer()
          let groups = ThreadTurnGroup.group(entries: page.entries)
          Text("共 \(groups.count) 轮对话 · \(page.entries.count) 条记录")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if page.entries.isEmpty {
          Text("该 Thread 没有可展示的文本消息。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          let groups = ThreadTurnGroup.group(entries: page.entries)
          VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
              ThreadChatBubbleView(group: group)
            }
          }
        }
      }
    }
  }

  private func chooseProject() {
    let panel = NSOpenPanel()
    panel.title = "选择要注册的项目目录"
    panel.prompt = "添加项目"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.registerProject(at: url)
  }
}

private struct ProjectPermissionEditor: View {
  @ObservedObject var model: BridgeServiceAppModel
  let project: MCPProjectSummary
  @State private var draft: BridgeProjectPolicyDraft
  @State private var showSavedFeedback = false

  init(model: BridgeServiceAppModel, project: MCPProjectSummary) {
    self.model = model
    self.project = project
    _draft = State(initialValue: BridgeProjectPolicyDraft(project: project))
  }

  var body: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        VStack(spacing: 12) {
          permissionPickerRow(
            "读取权限", symbol: "doc.text.magnifyingglass", selection: $draft.readPermission)
          Divider()
          permissionPickerRow(
            "写入权限", symbol: "pencil.and.outline", selection: $draft.writePermission)
          Divider()
          permissionPickerRow("网络权限", symbol: "network", selection: $draft.networkPermission)
        }

        Divider()

        HStack(spacing: 12) {
          Button("保存权限配置") {
            model.updateProjectPolicy(projectID: project.projectID, draft: draft)
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
          .disabled(!hasChanges)

          if showSavedFeedback {
            HStack(spacing: 4) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("权限已保存生效")
                .font(.caption)
                .foregroundStyle(.green)
            }
            .transition(.opacity)
          } else if !hasChanges {
            HStack(spacing: 4) {
              Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
              Text("已是最新生效状态")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Text("安全原则：ChatGPT 和 Supervisor 永远不能代替本机用户批准 Codex 操作。")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .onChange(of: project) {
      if !hasChanges {
        draft = BridgeProjectPolicyDraft(project: project)
      }
    }
  }

  private var hasChanges: Bool {
    draft != BridgeProjectPolicyDraft(project: project)
  }

  private func permissionPickerRow(
    _ title: String,
    symbol: String,
    selection: Binding<String>
  ) -> some View {
    HStack(alignment: .center) {
      Label(title, systemImage: symbol)
        .font(.subheadline.weight(.medium))
        .frame(width: 120, alignment: .leading)

      Spacer()

      Picker(title, selection: selection) {
        Text("拒绝").tag("denied")
        Text("需要本机批准").tag("requiresLocalApproval")
        Text("允许").tag("allowed")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 320)
    }
  }
}

private struct ProjectWorkspaceEditor: View {
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
          Label("ChatGPT Direct 命令", systemImage: "terminal")
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
          "默认仍由 Codex 执行项目任务。这里配置的是用户在 ChatGPT 对话中明确要求\u{201C}直接执行\u{201D}时，网页 GPT 可以使用的本地命令。"
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
      return "禁止 ChatGPT 直接执行任何命令。"
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

private struct BlacklistRow: View {
  @Binding var draft: BridgeBlacklistDraft
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField("可执行文件（可选）", text: $draft.executable)
          .textFieldStyle(.roundedBorder)
        TextField("参数子串（可选）", text: $draft.pattern)
          .textFieldStyle(.roundedBorder)
        Spacer()
        Button(role: .destructive) {
          onRemove()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(10)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.red.opacity(0.35), lineWidth: 0.8)
    )
  }
}

private struct ProjectCommandRow: View {
  @Binding var draft: BridgeWorkspaceCommandDraft
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField("命令名称", text: $draft.name)
          .textFieldStyle(.roundedBorder)
        Spacer()
        Button(role: .destructive) {
          onRemove()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
      }

      HStack(spacing: 8) {
        TextField("可执行文件 / 脚本路径", text: $draft.executable)
          .textFieldStyle(.roundedBorder)
      }

      HStack(spacing: 8) {
        TextField("参数前缀（每行一个，可选）", text: $draft.arguments, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(2...4)

        TextField("工作目录（相对项目根，可选）", text: $draft.workingDirectory)
          .textFieldStyle(.roundedBorder)
      }

      HStack(spacing: 12) {
        Toggle("需要网络", isOn: $draft.requiresNetwork)
          .toggleStyle(.switch)
          .controlSize(.small)

        Picker("风险", selection: $draft.risk) {
          Text("普通").tag("normal")
          Text("高风险（每次需批准）").tag("elevated")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)

        Spacer()
      }
    }
    .padding(10)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
    )
  }
}
