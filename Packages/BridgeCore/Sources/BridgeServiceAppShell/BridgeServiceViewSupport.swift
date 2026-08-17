import BridgeMCP
import SwiftUI

struct ServiceStatusLabel: View {
  let title: String
  let value: String
  let symbol: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .imageScale(.medium)
        .foregroundStyle(statusStyle)
        .accessibilityHidden(true)
      Text(title)
      Spacer(minLength: 16)
      Text(value)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  private var statusStyle: HierarchicalShapeStyle {
    .secondary
  }
}

struct SectionHeader: View {
  let title: String
  let subtitle: String?

  init(_ title: String, subtitle: String? = nil) {
    self.title = title
    self.subtitle = subtitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.title2.weight(.semibold))
      if let subtitle {
        Text(subtitle)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct TaskStatusLabel: View {
  let status: String

  var body: some View {
    Label(label, systemImage: symbol)
      .foregroundStyle(style)
      .help(status)
  }

  private var label: String {
    switch status {
    case "awaiting_local_approval": "等待本机批准"
    case "starting": "正在启动"
    case "running": "运行中"
    case "waiting_for_codex_approval": "等待 Codex 审批"
    case "completed": "已完成"
    case "failed": "失败"
    case "interrupted": "已中断"
    case "unknown": "状态未知"
    default: status
    }
  }

  private var symbol: String {
    switch status {
    case "completed": "checkmark.circle.fill"
    case "failed": "xmark.circle.fill"
    case "interrupted": "stop.circle.fill"
    case "awaiting_local_approval", "waiting_for_codex_approval":
      "exclamationmark.triangle.fill"
    case "starting", "running": "clock.arrow.circlepath"
    default: "questionmark.circle"
    }
  }

  private var style: AnyShapeStyle {
    switch status {
    case "completed": AnyShapeStyle(.green)
    case "failed": AnyShapeStyle(.red)
    case "awaiting_local_approval", "waiting_for_codex_approval":
      AnyShapeStyle(.orange)
    default: AnyShapeStyle(.secondary)
    }
  }
}

extension MCPServiceExposureMode {
  var localizedTitle: String {
    switch self {
    case .readOnly: "只读"
    case .full: "完整操作"
    }
  }
}
