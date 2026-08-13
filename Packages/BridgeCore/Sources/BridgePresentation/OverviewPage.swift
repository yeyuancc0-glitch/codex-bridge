import SwiftUI

struct OverviewPage: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      PageHeader(
        title: "概览",
        subtitle: "连接健康、待处理决定与真实任务活动",
        refreshAction: { await store.perform(.refresh(.overview)) }
      )
      LoadStateView(
        state: store.snapshot.overview,
        retry: { await store.perform(.refresh(.overview)) }
      ) { overview in
        OverviewContent(overview: overview, store: store)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }
}

private struct OverviewContent: View {
  let overview: OverviewPresentation
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingPage) {
        connectionSection
        attentionSection
        taskSection(title: "正在运行", tasks: overview.activeTasks)
        taskSection(title: "最近完成", tasks: overview.recentTasks)
        evidenceSummary
      }
      .frame(maxWidth: 960, alignment: .leading)
    }
  }

  private var connectionSection: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("真实连接路径", detail: "每个节点均来自最近一次健康检查")
      ForEach(overview.connectionPath) { node in
        StatusRow(title: node.title, detail: node.detail, status: node.status)
        if node.id != overview.connectionPath.last?.id { Divider() }
      }
    }
  }

  private var attentionSection: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("需要处理")
      if overview.attentionItems.isEmpty {
        Label("当前没有待处理事项", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(overview.attentionItems) { item in
          Button {
            store.destination = item.destination
          } label: {
            StatusRow(title: item.title, detail: item.detail, status: item.status)
          }
          .buttonStyle(.plain)
          Divider()
        }
      }
    }
  }

  @ViewBuilder
  private func taskSection(title: String, tasks: [TaskRowPresentation]) -> some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading(title)
      if tasks.isEmpty {
        Text("无任务")
          .foregroundStyle(.secondary)
      } else {
        ForEach(tasks) { task in
          Button {
            store.destination = .tasks
            store.selectTask(task.id)
          } label: {
            TaskCompactRow(task: task)
          }
          .buttonStyle(.plain)
          Divider()
        }
      }
    }
  }

  private var evidenceSummary: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("运行事实")
      MetadataRow(label: "已注册项目", value: String(overview.registeredProjectCount))
      if let refreshedAt = overview.modelCatalogRefreshedAt {
        MetadataRow(
          label: "模型目录刷新",
          value: "\(refreshedAt.value.bridgeFormatted) · \(refreshedAt.source)"
        )
      }
      if let rateLimitSummary = overview.rateLimitSummary {
        MetadataRow(label: "今日速率限制", value: rateLimitSummary)
      }
    }
  }
}

struct TaskCompactRow: View {
  let task: TaskRowPresentation

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: BridgeTheme.spacingRegular) {
      Image(systemName: task.status.systemImage)
        .foregroundStyle(task.status.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
        Text(task.title)
          .font(.body.weight(.medium))
        Text("\(task.projectName) · \(task.threadLabel) · \(task.model)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer()
      Text(task.updatedAt.bridgeFormatted)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(task.title)，\(task.status.accessibilitySummary)，项目 \(task.projectName)，模型 \(task.model)"
    )
  }
}
