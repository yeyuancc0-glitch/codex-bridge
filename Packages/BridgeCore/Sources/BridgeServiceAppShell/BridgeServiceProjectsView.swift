import AppKit
import BridgeMCP
import SwiftUI

struct BridgeServiceProjectsView: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var taskPendingDeletion: MCPServiceTaskSnapshot?

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
    .alert(
      "删除会话？",
      isPresented: Binding(
        get: { taskPendingDeletion != nil },
        set: { visible in
          if !visible { taskPendingDeletion = nil }
        }
      ),
      presenting: taskPendingDeletion
    ) { task in
      Button("删除", role: .destructive) {
        taskPendingDeletion = nil
        model.deleteTask(task.taskID)
      }
      Button("取消", role: .cancel) {
        taskPendingDeletion = nil
      }
    } message: { _ in
      Text("该操作会删除此会话在 Codex Bridge 中保存的任务、事件和对话记录，无法撤销。")
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

          ProjectSkillsSection(model: model)
            .id(project.projectID)

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
            HStack(spacing: 0) {
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
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)

              if let task = task(for: thread) {
                Divider()
                  .frame(height: 28)
                  .padding(.horizontal, 10)

                Button(role: .destructive) {
                  taskPendingDeletion = task
                } label: {
                  Image(systemName: "trash")
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!task.isTerminal)
                .help(task.isTerminal ? "删除会话" : "运行中的会话不能删除")
                .accessibilityLabel("删除会话")
              }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
            )
          }
        }
      }

      if let selectedThread = model.selectedThread {
        threadTranscript(selectedThread)
      }
    }
  }

  private func task(for thread: MCPThreadSummary) -> MCPServiceTaskSnapshot? {
    model.tasks.first {
      $0.projectID == model.selectedProjectID && $0.threadID == thread.threadID
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
