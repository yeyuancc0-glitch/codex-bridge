import AppKit
import BridgeMCP
import SwiftUI

struct BridgeServiceProjectsView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    HSplitView {
      projectList
        .frame(minWidth: 260, idealWidth: 320)
      projectDetail
        .frame(minWidth: 480)
    }
    .navigationTitle("项目")
  }

  private var projectList: some View {
    VStack(spacing: 0) {
      HStack {
        Text("注册项目")
          .font(.headline)
        Spacer()
        Button {
          chooseProject()
        } label: {
          Label("添加项目", systemImage: "plus")
        }
      }
      .padding(16)

      Divider()

      if model.projects.isEmpty {
        ContentUnavailableView(
          "尚未注册项目",
          systemImage: "folder.badge.plus",
          description: Text("只有你明确添加的目录才能被 ChatGPT 和 Codex Bridge 访问。")
        )
      } else {
        List(selection: projectSelection) {
          ForEach(model.projects, id: \.projectID) { project in
            VStack(alignment: .leading, spacing: 4) {
              Text(project.name)
              Text(project.projectID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            .tag(project.projectID)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var projectDetail: some View {
    if let project = selectedProject {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack(alignment: .firstTextBaseline) {
            SectionHeader(project.name, subtitle: project.projectID)
            Spacer()
            Button("移除", role: .destructive) {
              model.removeProject(project.projectID)
            }
          }

          ProjectPermissionEditor(model: model, project: project)
            .id(project.projectID + permissionFingerprint(project))
          Divider()
          threadsSection
        }
        .padding(24)
        .frame(maxWidth: 900, alignment: .leading)
      }
    } else {
      ContentUnavailableView(
        "选择一个项目",
        systemImage: "folder",
        description: Text("查看权限和项目绑定的 Codex Thread。")
      )
    }
  }

  private var projectSelection: Binding<String?> {
    Binding(
      get: { model.selectedProjectID },
      set: { value in
        guard let value else { return }
        model.selectProject(value)
      }
    )
  }

  private var selectedProject: MCPProjectSummary? {
    guard let selectedProjectID = model.selectedProjectID else { return nil }
    return model.projects.first(where: { $0.projectID == selectedProjectID })
  }

  private var threadsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Codex Threads")
          .font(.headline)
        Spacer()
        if let projectID = model.selectedProjectID {
          Button("刷新 Threads") {
            model.selectProject(projectID)
          }
        }
      }

      if model.threads.isEmpty {
        Text("该项目目前没有可读取的 Codex Thread。")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.threads, id: \.threadID) { thread in
          Button {
            model.openThread(thread.threadID)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(thread.title ?? thread.preview ?? thread.threadID)
                  .lineLimit(1)
                Spacer()
                Text(thread.status)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Text(thread.threadID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          Divider()
        }
      }

      if let selectedThread = model.selectedThread {
        threadTranscript(selectedThread)
      }
    }
  }

  private func threadTranscript(_ page: MCPThreadReadPage) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Thread 对话")
        .font(.headline)
      if page.entries.isEmpty {
        Text("该 Thread 没有可展示的文本消息。")
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(page.entries.enumerated()), id: \.offset) { _, entry in
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.role == "assistant" ? "Codex" : "用户")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(entry.text)
              .textSelection(.enabled)
          }
          .padding(.vertical, 6)
        }
      }
    }
    .padding(.top, 8)
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

  private func permissionFingerprint(_ project: MCPProjectSummary) -> String {
    project.capabilities.read + project.capabilities.write + project.capabilities.network
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
    VStack(alignment: .leading, spacing: 12) {
      Text("权限")
        .font(.headline)
      permissionPicker("读取", selection: $draft.readPermission)
      permissionPicker("写入", selection: $draft.writePermission)
      permissionPicker("网络", selection: $draft.networkPermission)
      HStack(spacing: 12) {
        Button("保存权限") {
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
            Text("已是最新配置")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Text("ChatGPT 和 Supervisor 永远不能代替本机用户批准 Codex 操作。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var hasChanges: Bool {
    draft != BridgeProjectPolicyDraft(project: project)
  }

  private func permissionPicker(
    _ title: String,
    selection: Binding<String>
  ) -> some View {
    Picker(title, selection: selection) {
      Text("拒绝").tag("denied")
      Text("需要本机批准").tag("requiresLocalApproval")
      Text("允许").tag("allowed")
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 480)
  }
}
