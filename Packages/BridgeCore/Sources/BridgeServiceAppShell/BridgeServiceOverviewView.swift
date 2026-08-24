import BridgeMCP
import SwiftUI

struct BridgeServiceOverviewView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SectionHeader(
          "概览",
          subtitle: "监控后台 Service、本地 MCP、Secure Tunnel 与任务执行状态。",
          icon: "gauge.with.needle"
        )

        attentionSection

        VStack(alignment: .leading, spacing: 12) {
          Text("关键指标")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          metricsGrid
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("连接与服务状态")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

          statusCard
        }

        if !model.tasks.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("最近任务")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
              Spacer()
              Button("进入工作台 →") {
                model.selection = .workbench
              }
              .buttonStyle(.link)
              .font(.caption.weight(.medium))
            }

            recentTasksCard
          }
        }
      }
      .padding(28)
      .frame(maxWidth: 960, alignment: .leading)
    }
    .navigationTitle("概览")
  }

  @ViewBuilder
  private var attentionSection: some View {
    if model.registrationStatus == .requiresApproval {
      CalloutBanner(
        title: "需要批准后台项目",
        message: "macOS 正在等待你在系统设置中批准 Codex Bridge 后台 LaunchAgent 项目。",
        symbol: "exclamationmark.triangle.fill",
        tone: .warning,
        actionTitle: "打开登录项设置"
      ) {
        model.openSystemSettings()
      }
    }

    if !model.approvals.isEmpty {
      CalloutBanner(
        title: "待处理 Codex 审批",
        message: "当前有 \(model.approvals.count) 个远程任务或 Codex 操作等待你本机确认或拒绝。",
        symbol: "exclamationmark.shield.fill",
        tone: .warning,
        actionTitle: "立即处理"
      ) {
        model.selection = .workbench
      }
    }
  }

  private var metricsGrid: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 14)], spacing: 14)
    {
      MetricCard(
        title: "注册项目",
        value: "\(model.projects.count)",
        symbol: "folder.fill",
        subtitle: "点击管理本地目录",
        tint: .blue,
        action: {
          model.selection = .projects
        }
      )

      MetricCard(
        title: "运行中任务",
        value: "\(model.runningTaskCount)",
        symbol: "bolt.fill",
        subtitle: model.runningTaskCount > 0 ? "点击进入工作台查看" : "当前空闲",
        tint: model.runningTaskCount > 0 ? .green : .secondary,
        action: {
          model.selection = .workbench
        }
      )

      MetricCard(
        title: "待审批项",
        value: "\(model.approvals.count)",
        symbol: "shield.lefthalf.filled",
        subtitle: model.approvals.isEmpty ? "无阻断事项" : "点击立即处理审批",
        tint: model.approvals.isEmpty ? .secondary : .orange,
        action: {
          model.selection = .workbench
        }
      )

      MetricCard(
        title: "任务总数",
        value: "\(model.tasks.count)",
        symbol: "list.bullet.rectangle",
        subtitle: lastRefreshSubtitle,
        tint: .purple,
        action: {
          model.selection = .logs
        }
      )
    }
  }

  private var statusCard: some View {
    NativeCard {
      VStack(spacing: 10) {
        ServiceStatusLabel(
          title: "后台 Service",
          value: model.connectionState.label,
          symbol: model.connectionState.symbol,
          tone: serviceTone
        )

        Divider()

        ServiceStatusLabel(
          title: "本地 MCP",
          value: model.serviceStatus?.status.mcpState ?? "未知",
          symbol: model.serviceStatus?.status.mcpState == "ready"
            ? "checkmark.circle.fill"
            : "circle.dashed",
          tone: model.serviceStatus?.status.mcpState == "ready" ? .success : .neutral
        )

        Divider()

        ServiceStatusLabel(
          title: "Secure Tunnel",
          value: tunnelStatusLabel,
          symbol: tunnelSymbol,
          tone: tunnelTone
        )

        Divider()

        ServiceStatusLabel(
          title: "MCP 工具权限模式",
          value: model.exposureMode.localizedTitle,
          symbol: model.exposureMode == .full ? "wrench.and.screwdriver.fill" : "eye.fill",
          tone: model.exposureMode == .full ? .info : .neutral
        )

        Divider()

        HStack {
          Button("管理连接与凭据 →") {
            model.selection = .connections
          }
          .buttonStyle(.link)
          .font(.caption.weight(.medium))

          Spacer()

          Button("配置模型与监督偏好 →") {
            model.selection = .settings
          }
          .buttonStyle(.link)
          .font(.caption.weight(.medium))
        }
        .padding(.top, 4)
      }
    }
  }

  private var recentTasksCard: some View {
    NativeCard {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(model.tasks.prefix(4)), id: \.taskID) { task in
          Button {
            if let threadID = task.threadID {
              model.openThread(threadID, inProject: task.projectID)
            }
            model.selection = .workbench
          } label: {
            HStack(alignment: .center, spacing: 12) {
              TaskStatusLabel(status: task.status)
                .frame(width: 98, alignment: .leading)

              StatusBadge(task.sourceDisplayName, tone: .neutral)
                .frame(width: 80, alignment: .leading)

              VStack(alignment: .leading, spacing: 2) {
                Text(task.currentStep ?? task.resultSummary ?? task.taskID)
                  .font(.system(size: 13, weight: .medium))
                  .lineLimit(1)
                  .foregroundStyle(.primary)

                HStack(spacing: 4) {
                  Image(systemName: "folder")
                    .font(.caption2)
                  Text(model.projectName(for: task.projectID))
                    .font(.caption)
                }
                .foregroundStyle(.secondary)
              }

              Spacer()

              Text(task.updatedAt)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

          if task.taskID != model.tasks.prefix(4).last?.taskID {
            Divider()
          }
        }
      }
    }
  }

  private var serviceTone: StatusTone {
    switch model.connectionState {
    case .connected: .success
    case .registering, .connecting: .running
    case .requiresApproval: .warning
    case .idle, .unavailable: .error
    }
  }

  private var tunnelStatusLabel: String {
    guard let tunnel = model.serviceStatus?.tunnel else { return "未配置" }
    return tunnel.lifecycle
  }

  private var tunnelTone: StatusTone {
    guard let tunnel = model.serviceStatus?.tunnel else { return .neutral }
    if tunnel.lifecycle == "ready" { return .success }
    if tunnel.actionRequired { return .warning }
    if tunnel.enabled { return .running }
    return .neutral
  }

  private var tunnelSymbol: String {
    guard let tunnel = model.serviceStatus?.tunnel else { return "link.badge.plus" }
    if tunnel.lifecycle == "ready" { return "checkmark.circle.fill" }
    if tunnel.actionRequired { return "exclamationmark.triangle.fill" }
    return "link"
  }

  private var lastRefreshSubtitle: String {
    if let last = model.lastRefreshAt {
      return "更新于 " + last.formatted(date: .omitted, time: .standard)
    }
    return "尚未刷新"
  }
}
