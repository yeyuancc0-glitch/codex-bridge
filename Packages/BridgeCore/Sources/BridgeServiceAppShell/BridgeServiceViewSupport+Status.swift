import BridgeMCP
import SwiftUI

public struct ToastHUDView: View {
  let toast: ToastNotice
  var onDismiss: (() -> Void)? = nil

  public init(toast: ToastNotice, onDismiss: (() -> Void)? = nil) {
    self.toast = toast
    self.onDismiss = onDismiss
  }

  public var body: some View {
    HStack(spacing: 10) {
      Image(systemName: toast.symbol)
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(toast.tone.foregroundColor)

      Text(toast.message)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)

      if let onDismiss {
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.leading, 4)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.regularMaterial)
    .clipShape(Capsule())
    .overlay(
      Capsule()
        .strokeBorder(toast.tone.borderColor, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
    .transition(
      .asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity).combined(
          with: .scale(scale: 0.95)),
        removal: .opacity.combined(with: .scale(scale: 0.9))
      ))
  }
}

public struct StatusBadge: View {
  public let title: String
  public let symbol: String?
  public let tone: StatusTone

  public init(_ title: String, symbol: String? = nil, tone: StatusTone = .neutral) {
    self.title = title
    self.symbol = symbol
    self.tone = tone
  }

  public var body: some View {
    HStack(spacing: 4) {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: 10, weight: .semibold))
      }
      Text(title)
        .font(.system(size: 11, weight: .medium))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .foregroundStyle(tone.foregroundColor)
    .background(tone.backgroundColor)
    .clipShape(Capsule())
    .overlay(
      Capsule()
        .strokeBorder(tone.borderColor, lineWidth: 0.8)
    )
  }
}

public struct ServiceStatusLabel: View {
  public let title: String
  public let value: String
  public let symbol: String
  public var tone: StatusTone = .neutral

  public init(title: String, value: String, symbol: String, tone: StatusTone = .neutral) {
    self.title = title
    self.value = value
    self.symbol = symbol
    self.tone = tone
  }

  public var body: some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(tone.backgroundColor)
          .frame(width: 26, height: 26)
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(tone.foregroundColor)
      }
      .accessibilityHidden(true)

      Text(title)
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)

      Spacer(minLength: 16)

      StatusBadge(value, tone: tone)
    }
    .padding(.vertical, 2)
  }
}

public struct TaskStatusLabel: View {
  public let status: String
  public let providerID: String?

  public init(status: String, providerID: String? = nil) {
    self.status = status
    self.providerID = providerID
  }

  public var body: some View {
    StatusBadge(label, symbol: symbol, tone: tone)
      .help(helpText)
  }

  private var label: String {
    return switch status {
    case "awaiting_local_approval": "等待本机批准"
    case "starting": "正在启动"
    case "running": "运行中"
    case "waiting_for_codex_approval": "等待 \(providerDisplayName) 审批"
    case "completed": "已完成"
    case "failed": "失败"
    case "interrupted": "已中断"
    case "unknown": "状态未知"
    default: status
    }
  }

  private var symbol: String {
    return switch status {
    case "completed": "checkmark.circle.fill"
    case "failed": "xmark.circle.fill"
    case "interrupted": "stop.circle.fill"
    case "awaiting_local_approval", "waiting_for_codex_approval":
      "exclamationmark.triangle.fill"
    case "starting", "running": "arrow.triangle.2.circlepath"
    default: "questionmark.circle"
    }
  }

  private var tone: StatusTone {
    return switch status {
    case "completed": .success
    case "failed": .error
    case "awaiting_local_approval", "waiting_for_codex_approval": .warning
    case "starting", "running": .running
    default: .neutral
    }
  }

  private var providerDisplayName: String {
    AgentProviderPresentation.displayName(providerID)
  }

  private var helpText: String {
    status
  }
}

public struct SaveFeedbackBadge: View {
  public let showSaved: Bool
  public let isModified: Bool
  public var savedText: String = "已保存生效"
  public var unmodifiedText: String = "已是最新生效状态"

  public init(
    showSaved: Bool,
    isModified: Bool,
    savedText: String = "已保存生效",
    unmodifiedText: String = "已是最新生效状态"
  ) {
    self.showSaved = showSaved
    self.isModified = isModified
    self.savedText = savedText
    self.unmodifiedText = unmodifiedText
  }

  public var body: some View {
    if showSaved {
      HStack(spacing: 4) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text(savedText)
          .font(.caption.weight(.medium))
          .foregroundStyle(.green)
      }
      .transition(.opacity.combined(with: .scale(scale: 0.95)))
    } else if !isModified {
      HStack(spacing: 4) {
        Image(systemName: "checkmark")
          .foregroundStyle(.secondary)
        Text(unmodifiedText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      HStack(spacing: 4) {
        Circle()
          .fill(Color.orange)
          .frame(width: 6, height: 6)
        Text("有未保存的改动")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}

extension MCPServiceExposureMode {
  public var localizedTitle: String {
    switch self {
    case .readOnly: "只读模式"
    case .full: "完整操作"
    }
  }
}
