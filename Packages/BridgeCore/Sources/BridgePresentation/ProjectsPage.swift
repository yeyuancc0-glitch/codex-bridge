import SwiftUI

struct ProjectsPage: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      PageHeader(
        title: "项目",
        subtitle: "项目白名单、Git 状态与明确的权限边界",
        refreshAction: { await store.perform(.refresh(.projects)) }
      )
      HStack {
        Spacer()
        Button("添加项目", systemImage: "folder.badge.plus") {
          Task { await store.perform(.addProject) }
        }
      }
      LoadStateView(
        state: store.snapshot.projects,
        retry: { await store.perform(.refresh(.projects)) }
      ) { page in
        ProjectWorkspace(page: page, store: store)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }
}

private struct ProjectWorkspace: View {
  let page: ProjectPagePresentation
  @ObservedObject var store: BridgePresentationStore

  @ViewBuilder
  var body: some View {
    if page.projects.isEmpty {
      ContentUnavailableView(
        "尚未注册项目",
        systemImage: "folder.badge.plus",
        description: Text("添加一个本机项目后，Bridge 才能读取或运行任务。")
      )
    } else {
      HSplitView {
        List(page.projects, selection: projectSelection) { project in
          ProjectRow(project: project)
            .tag(project.id)
            .padding(.vertical, BridgeTheme.spacingTight)
        }
        .frame(minWidth: 240, idealWidth: 300)
        .accessibilityLabel("已注册项目")
        detail
          .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
          .padding(.leading, BridgeTheme.spacingSection)
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let selectedProjectID = store.selectedProjectID,
      let project = page.projects.first(where: { $0.id == selectedProjectID })
    {
      ProjectDetail(project: project, store: store)
    } else {
      ContentUnavailableView("选择项目", systemImage: "folder", description: Text("查看授权和 Git 事实。"))
    }
  }

  private var projectSelection: Binding<String?> {
    Binding(
      get: { store.selectedProjectID },
      set: { store.selectProject($0) }
    )
  }
}

private struct ProjectRow: View {
  let project: ProjectPresentation

  var body: some View {
    HStack(spacing: BridgeTheme.spacingRegular) {
      Image(systemName: project.isAvailable ? "folder.fill" : "externaldrive.badge.xmark")
        .foregroundStyle(project.isAvailable ? Color.accentColor : Color.red)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
        Text(project.name)
          .font(.body.weight(.medium))
        Text(project.branchDisplayValue)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if project.showsDirtyIndicator {
        Label("有未提交修改", systemImage: "circle.fill")
          .labelStyle(.iconOnly)
          .foregroundStyle(.orange)
          .help("工作区有未提交修改")
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(project.name)，\(project.isAvailable ? "可用" : "离线")，\(project.workingTreeDisplayValue)"
    )
  }
}

private struct ProjectDetail: View {
  let project: ProjectPresentation
  @ObservedObject var store: BridgePresentationStore
  @State private var showsRemovalConfirmation = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
        HStack {
          VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
            Text(project.name)
              .font(.title3.weight(.semibold))
            StatusLabel(status: project.isAvailable ? .ready : .disconnected)
          }
          Spacer()
          Button("打开项目", systemImage: "arrow.up.forward.app") {
            Task { await store.perform(.openProject(project.id)) }
          }
          .disabled(!project.isAvailable)
        }
        Divider()
        SectionHeading("路径与 Git")
        MetadataRow(label: "规范化路径", value: project.normalizedPath, monospaced: true)
        MetadataRow(label: "分支", value: project.branchDisplayValue, monospaced: true)
        MetadataRow(label: "工作区", value: project.workingTreeDisplayValue)
        SectionHeading("权限")
        ProjectPolicyEditor(project: project, store: store)
          .id(projectPolicyIdentity)
        SectionHeading("验证命令")
        if project.verificationCommands.isEmpty {
          Text("未配置验证命令")
            .foregroundStyle(.secondary)
        } else {
          ForEach(project.verificationCommands, id: \.self) { command in
            EvidenceText(text: command)
          }
        }
        SectionHeading("使用情况")
        MetadataRow(
          label: "线程数量",
          value: project.threadCountDisplayValue
        )
        MetadataRow(label: "最近任务", value: project.lastTaskTitle ?? "无")
        Divider()
        Button("移除项目", systemImage: "trash", role: .destructive) {
          showsRemovalConfirmation = true
        }
        .confirmationDialog(
          "从 Bridge 移除“\(project.name)”？",
          isPresented: $showsRemovalConfirmation,
          titleVisibility: .visible
        ) {
          Button("移除项目", role: .destructive) {
            Task { await store.perform(.removeProject(project.id)) }
          }
          Button("取消", role: .cancel) {}
        } message: {
          Text("只会删除 Bridge 的注册信息，不会删除本机项目文件。存在活动任务时操作会被拒绝。")
        }
      }
      .frame(maxWidth: BridgeTheme.readableTextWidth, alignment: .leading)
    }
  }

  private var projectPolicyIdentity: String {
    [
      project.id,
      project.readPermission.rawValue,
      project.writePermission.rawValue,
      project.networkPermission.rawValue,
    ].joined(separator: ":")
  }
}

private struct ProjectPolicyEditor: View {
  let project: ProjectPresentation
  @ObservedObject var store: BridgePresentationStore
  @State private var readPermission: ProjectPermissionPresentation
  @State private var writePermission: ProjectPermissionPresentation
  @State private var networkPermission: ProjectPermissionPresentation

  init(project: ProjectPresentation, store: BridgePresentationStore) {
    self.project = project
    self.store = store
    _readPermission = State(initialValue: project.readPermission)
    _writePermission = State(initialValue: project.writePermission)
    _networkPermission = State(initialValue: project.networkPermission)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      ProjectPermissionPicker(
        title: "读取",
        selection: $readPermission,
        options: [.allowed, .denied]
      )
      ProjectPermissionPicker(
        title: "写入",
        selection: $writePermission,
        options: [.requiresLocalApproval, .allowed, .denied]
      )
      ProjectPermissionPicker(
        title: "网络",
        selection: $networkPermission,
        options: [.denied, .requiresLocalApproval, .allowed]
      )
      HStack {
        Text(project.isAvailable ? "策略保存到本机项目注册表。" : "项目离线时不能修改策略。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("保存权限", systemImage: "checkmark") {
          Task {
            await store.perform(
              .updateProjectAccessPolicy(
                projectID: project.id,
                read: readPermission,
                write: writePermission,
                network: networkPermission
              )
            )
          }
        }
        .disabled(!project.isAvailable || !hasChanges)
      }
    }
  }

  private var hasChanges: Bool {
    readPermission != project.readPermission || writePermission != project.writePermission
      || networkPermission != project.networkPermission
  }
}

private struct ProjectPermissionPicker: View {
  let title: String
  @Binding var selection: ProjectPermissionPresentation
  let options: [ProjectPermissionPresentation]

  var body: some View {
    Picker(title, selection: $selection) {
      ForEach(options, id: \.self) { permission in
        Text(permission.displayName).tag(permission)
      }
    }
    .pickerStyle(.menu)
    .accessibilityLabel("\(title)权限")
  }
}

extension ProjectPermissionPresentation {
  fileprivate var displayName: String {
    switch self {
    case .allowed: "允许"
    case .requiresLocalApproval: "需要本机确认"
    case .denied: "不允许"
    }
  }
}
