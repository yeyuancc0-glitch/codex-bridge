import SwiftUI

struct BridgeServiceOverviewView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SectionHeader(
          "概览",
          subtitle: "查看后台 Service、任务与本机审批是否需要处理。"
        )

        statusSection
        Divider()
        attentionSection
        Divider()
        activitySection
      }
      .padding(24)
      .frame(maxWidth: 900, alignment: .leading)
    }
    .navigationTitle("概览")
  }

  private var statusSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("运行状态")
        .font(.headline)
      ServiceStatusLabel(
        title: "后台 Service",
        value: model.connectionState.label,
        symbol: model.connectionState.symbol
      )
      ServiceStatusLabel(
        title: "本地 MCP",
        value: model.serviceStatus?.status.mcpState ?? "未知",
        symbol: model.serviceStatus?.status.mcpState == "ready"
          ? "checkmark.circle.fill"
          : "circle.dashed"
      )
      ServiceStatusLabel(
        title: "远程 Tunnel",
        value: model.serviceStatus?.status.tunnelState ?? "未配置",
        symbol: model.serviceStatus?.status.tunnelState == "ready"
          ? "checkmark.circle.fill"
          : "link.badge.plus"
      )
      ServiceStatusLabel(
        title: "MCP 权限模式",
        value: model.exposureMode.localizedTitle,
        symbol: model.exposureMode == .full ? "wrench.and.screwdriver" : "eye"
      )
    }
  }

  private var attentionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("需要处理")
        .font(.headline)
      if model.registrationStatus == .requiresApproval {
        Label(
          "macOS 正在等待你批准 Codex Bridge 后台项目。",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        Button("打开登录项设置") {
          model.openSystemSettings()
        }
      }
      if model.pendingLocalTaskCount > 0 {
        Button("有 \(model.pendingLocalTaskCount) 个任务等待本机批准") {
          model.selection = .tasks
        }
      }
      if !model.approvals.isEmpty {
        Button("有 \(model.approvals.count) 个 Codex 操作等待决定") {
          model.selection = .tasks
        }
      }
      if model.registrationStatus != .requiresApproval,
        model.pendingLocalTaskCount == 0,
        model.approvals.isEmpty
      {
        Label("当前没有待处理事项。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var activitySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("当前活动")
        .font(.headline)
      LabeledContent("注册项目", value: "\(model.projects.count)")
      LabeledContent("运行中任务", value: "\(model.runningTaskCount)")
      LabeledContent("任务总数", value: "\(model.tasks.count)")
      if let lastRefreshAt = model.lastRefreshAt {
        LabeledContent("最近刷新") {
          Text(lastRefreshAt, style: .relative)
        }
      }
    }
  }
}
