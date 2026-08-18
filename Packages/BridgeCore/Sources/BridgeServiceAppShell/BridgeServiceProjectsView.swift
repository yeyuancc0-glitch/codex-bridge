import AppKit
import BridgeMCP
import SwiftUI

struct BridgeServiceProjectsView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    HSplitView {
      projectList
        .frame(minWidth: 280, idealWidth: 320)
      projectDetail
        .frame(minWidth: 500)
    }
    .navigationTitle("项目")
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
        .buttonStyle(.bordered)
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
        List(selection: projectSelection) {
          ForEach(model.projects, id: \.projectID) { project in
            HStack(spacing: 10) {
              Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(.blue)

              VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                  .font(.body.weight(.medium))
                  .lineLimit(1)

                Text(project.projectID)
                  .font(.system(size: 10, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }

              Spacer()

              if model.selectedProjectID == project.projectID {
                Image(systemName: "chevron.right")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 4)
            .tag(project.projectID)
          }
        }
        .listStyle(.sidebar)
      }
    }
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
              .id(project.projectID + permissionFingerprint(project))
          }

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

  private func threadTranscript(_ page: MCPThreadReadPage) -> some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Thread 对话历史", systemImage: "bubble.left.and.text.bubble.right.fill")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text("共 \(page.entries.count) 条消息")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if page.entries.isEmpty {
          Text("该 Thread 没有可展示的文本消息。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(page.entries.enumerated()), id: \.offset) { _, entry in
              let isAssistant = entry.role == "assistant"
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: isAssistant ? "cpu.fill" : "person.fill")
                  .font(.system(size: 13))
                  .foregroundStyle(isAssistant ? Color.purple : Color.blue)
                  .frame(width: 24, height: 24)
                  .background(isAssistant ? Color.purple.opacity(0.12) : Color.blue.opacity(0.12))
                  .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                  Text(isAssistant ? "Codex" : "用户")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isAssistant ? .purple : .blue)

                  Text(entry.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                isAssistant
                  ? Color(nsColor: .textBackgroundColor).opacity(0.5)
                  : Color.blue.opacity(0.04)
              )
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
