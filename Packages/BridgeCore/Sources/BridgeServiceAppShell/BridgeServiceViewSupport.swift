import AppKit
import BridgeMCP
import SwiftUI

public enum StatusTone: Sendable {
  case neutral
  case success
  case warning
  case error
  case info
  case running

  public var foregroundColor: Color {
    switch self {
    case .neutral: .secondary
    case .success: .green
    case .warning: .orange
    case .error: .red
    case .info: .blue
    case .running: .cyan
    }
  }

  public var backgroundColor: Color {
    switch self {
    case .neutral: Color(nsColor: .quaternaryLabelColor).opacity(0.15)
    case .success: Color.green.opacity(0.12)
    case .warning: Color.orange.opacity(0.12)
    case .error: Color.red.opacity(0.12)
    case .info: Color.blue.opacity(0.12)
    case .running: Color.cyan.opacity(0.12)
    }
  }

  public var borderColor: Color {
    switch self {
    case .neutral: Color(nsColor: .separatorColor).opacity(0.3)
    case .success: Color.green.opacity(0.25)
    case .warning: Color.orange.opacity(0.25)
    case .error: Color.red.opacity(0.25)
    case .info: Color.blue.opacity(0.25)
    case .running: Color.cyan.opacity(0.25)
    }
  }
}

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

public struct SectionHeader: View {
  public let title: String
  public let subtitle: String?
  public let icon: String?

  public init(_ title: String, subtitle: String? = nil, icon: String? = nil) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if let icon {
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(0.12))
            .frame(width: 34, height: 34)
          Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(.primary)

        if let subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
      .help(status)
  }

  private var label: String {
    switch status {
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
    switch status {
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
    switch status {
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
}

public struct NativeCard<Content: View>: View {
  public let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
    )
  }
}

public struct MetricCard: View {
  public let title: String
  public let value: String
  public let symbol: String
  public var subtitle: String? = nil
  public var tint: Color = .blue
  public var action: (() -> Void)? = nil

  @State private var isHovered = false

  public init(
    title: String,
    value: String,
    symbol: String,
    subtitle: String? = nil,
    tint: Color = .blue,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.value = value
    self.symbol = symbol
    self.subtitle = subtitle
    self.tint = tint
    self.action = action
  }

  public var body: some View {
    let cardContent = VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer()
        ZStack {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.opacity(0.12))
            .frame(width: 28, height: 28)
          Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
        }
      }

      HStack(alignment: .lastTextBaseline, spacing: 6) {
        Text(value)
          .font(.system(size: 26, weight: .bold, design: .rounded))
          .foregroundStyle(.primary)

        if action != nil {
          Spacer()
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(isHovered ? tint : Color.secondary.opacity(0.4))
        }
      }

      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
    .background(
      isHovered && action != nil
        ? Color(nsColor: .controlBackgroundColor).opacity(0.9)
        : Color(nsColor: .controlBackgroundColor)
    )
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(
          isHovered && action != nil
            ? tint.opacity(0.45)
            : Color(nsColor: .separatorColor).opacity(0.35),
          lineWidth: isHovered && action != nil ? 1.2 : 0.8
        )
    )

    if let action {
      Button(action: action) {
        cardContent
      }
      .buttonStyle(.plain)
      .onHover { hovering in
        withAnimation(.easeInOut(duration: 0.15)) {
          isHovered = hovering
        }
      }
    } else {
      cardContent
    }
  }
}

public struct CalloutBanner: View {
  public let title: String
  public let message: String
  public let symbol: String
  public let tone: StatusTone
  public var actionTitle: String? = nil
  public var action: (() -> Void)? = nil

  public init(
    title: String,
    message: String,
    symbol: String,
    tone: StatusTone,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.symbol = symbol
    self.tone = tone
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(tone.foregroundColor)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(tone.foregroundColor)

        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let actionTitle, let action {
          Button(actionTitle) {
            action()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .padding(.top, 4)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(tone.borderColor, lineWidth: 0.8)
    )
  }
}

public struct CodeSnippetBlock: View {
  public let text: String
  public var label: String? = nil
  public var onCopy: (() -> Void)? = nil

  @State private var isCopied = false

  public init(text: String, label: String? = nil, onCopy: (() -> Void)? = nil) {
    self.text = text
    self.label = label
    self.onCopy = onCopy
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let label {
        HStack {
          Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            copyText()
          } label: {
            HStack(spacing: 4) {
              Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
              Text(isCopied ? "已复制" : "复制")
                .font(.caption2.weight(isCopied ? .semibold : .regular))
            }
            .foregroundStyle(isCopied ? Color.green : Color.accentColor)
          }
          .buttonStyle(.borderless)
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        Text(text)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(
            isCopied ? Color.green.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.35),
            lineWidth: 0.8
          )
      )
    }
  }

  private func copyText() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
      isCopied = true
    }
    onCopy?()
    Task {
      try? await Task.sleep(for: .seconds(2))
      withAnimation(.easeInOut(duration: 0.2)) {
        isCopied = false
      }
    }
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

// MARK: - Thread Chat Models & Components

public struct ThreadTurnGroup: Identifiable, Equatable, Sendable {
  public let id: String
  public let role: String  // "user" or "assistant"
  public let thoughts: [String]
  public let mainText: String

  public init(id: String, role: String, thoughts: [String], mainText: String) {
    self.id = id
    self.role = role
    self.thoughts = thoughts
    self.mainText = mainText
  }

  public static func group(entries: [MCPThreadEntry]) -> [ThreadTurnGroup] {
    var groups: [ThreadTurnGroup] = []
    var currentTurnID: String?
    var currentRole: String?
    var currentTexts: [String] = []

    func flush() {
      guard let turnID = currentTurnID, let role = currentRole, !currentTexts.isEmpty else {
        currentTexts.removeAll()
        return
      }
      if role == "user" {
        for (index, text) in currentTexts.enumerated() {
          groups.append(
            ThreadTurnGroup(
              id: "\(turnID)_user_\(index)",
              role: "user",
              thoughts: [],
              mainText: text
            )
          )
        }
      } else {
        if currentTexts.count > 1 {
          let thoughts = Array(currentTexts.dropLast())
          let mainText = currentTexts.last ?? ""
          groups.append(
            ThreadTurnGroup(
              id: "\(turnID)_assistant_\(groups.count)",
              role: "assistant",
              thoughts: thoughts,
              mainText: mainText
            )
          )
        } else if let onlyText = currentTexts.first {
          groups.append(
            ThreadTurnGroup(
              id: "\(turnID)_assistant_\(groups.count)",
              role: "assistant",
              thoughts: [],
              mainText: onlyText
            )
          )
        }
      }
      currentTexts.removeAll()
    }

    for entry in entries {
      if entry.turnID == currentTurnID && entry.role == currentRole {
        currentTexts.append(entry.text)
      } else {
        flush()
        currentTurnID = entry.turnID
        currentRole = entry.role
        currentTexts = [entry.text]
      }
    }
    flush()
    return groups
  }
}

struct ThreadChatBubbleView: View {
  let group: ThreadTurnGroup

  var body: some View {
    let isUser = group.role == "user"
    HStack(alignment: .top, spacing: 0) {
      if isUser {
        Spacer(minLength: 40)
      }

      VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
        HStack(spacing: 4) {
          if isUser {
            Text("我")
              .font(.caption2.weight(.bold))
              .foregroundStyle(Color.blue)
            Image(systemName: "person.crop.circle.fill")
              .font(.caption2)
              .foregroundStyle(Color.blue)
          } else {
            Image(systemName: "cpu.fill")
              .font(.caption2)
              .foregroundStyle(Color.purple)
            Text("Codex")
              .font(.caption2.weight(.bold))
              .foregroundStyle(Color.purple)
          }
        }
        .padding(.horizontal, 2)

        VStack(alignment: .leading, spacing: 8) {
          if !group.thoughts.isEmpty {
            CodexThoughtsDisclosureView(thoughts: group.thoughts)
          }

          if !group.mainText.isEmpty {
            Text(group.mainText)
              .font(.system(size: 13))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(12)
        .background(
          isUser
            ? Color.blue.opacity(0.08)
            : Color(nsColor: .textBackgroundColor).opacity(0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
              isUser ? Color.blue.opacity(0.25) : Color(nsColor: .separatorColor).opacity(0.35),
              lineWidth: 0.8
            )
        )
      }

      if !isUser {
        Spacer(minLength: 40)
      }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }
}

struct CodexThoughtsDisclosureView: View {
  let thoughts: [String]
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .bold))
          Image(systemName: "brain.head.profile")
            .font(.caption2)
          Text("思考与执行步骤 (\(thoughts.count))")
            .font(.caption2.weight(.semibold))
          Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .buttonStyle(.plain)

      if isExpanded {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(thoughts.enumerated()), id: \.offset) { index, thought in
            HStack(alignment: .top, spacing: 6) {
              Text("\(index + 1).")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
              Text(thought)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
        }
        .padding(.top, 2)
      }
    }
  }
}
