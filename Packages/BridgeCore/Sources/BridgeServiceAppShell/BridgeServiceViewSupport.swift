import AppKit
import BridgeMCP
import SwiftUI

enum StatusTone {
  case neutral
  case success
  case warning
  case error
  case info
  case running

  var foregroundColor: Color {
    switch self {
    case .neutral: .secondary
    case .success: .green
    case .warning: .orange
    case .error: .red
    case .info: .blue
    case .running: .cyan
    }
  }

  var backgroundColor: Color {
    switch self {
    case .neutral: Color(nsColor: .quaternaryLabelColor).opacity(0.15)
    case .success: Color.green.opacity(0.12)
    case .warning: Color.orange.opacity(0.12)
    case .error: Color.red.opacity(0.12)
    case .info: Color.blue.opacity(0.12)
    case .running: Color.cyan.opacity(0.12)
    }
  }

  var borderColor: Color {
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

struct StatusBadge: View {
  let title: String
  let symbol: String?
  let tone: StatusTone

  init(_ title: String, symbol: String? = nil, tone: StatusTone = .neutral) {
    self.title = title
    self.symbol = symbol
    self.tone = tone
  }

  var body: some View {
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

struct ServiceStatusLabel: View {
  let title: String
  let value: String
  let symbol: String
  var tone: StatusTone = .neutral

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(tone.foregroundColor)
        .frame(width: 20, alignment: .center)
        .accessibilityHidden(true)

      Text(title)
        .font(.body)

      Spacer(minLength: 16)

      StatusBadge(value, tone: tone)
    }
    .padding(.vertical, 3)
  }
}

struct SectionHeader: View {
  let title: String
  let subtitle: String?
  let icon: String?

  init(_ title: String, subtitle: String? = nil, icon: String? = nil) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        if let icon {
          Image(systemName: icon)
            .font(.title3.weight(.medium))
            .foregroundStyle(.tint)
        }
        Text(title)
          .font(.title2.weight(.bold))
      }
      if let subtitle {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct TaskStatusLabel: View {
  let status: String

  var body: some View {
    StatusBadge(label, symbol: symbol, tone: tone)
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
}

struct NativeCard<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.8)
    )
  }
}

struct MetricCard: View {
  let title: String
  let value: String
  let symbol: String
  var subtitle: String? = nil
  var tint: Color = .blue

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer()
        Image(systemName: symbol)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tint)
      }

      Text(value)
        .font(.system(size: 24, weight: .bold, design: .rounded))
        .foregroundStyle(.primary)

      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.8)
    )
  }
}

struct CalloutBanner: View {
  let title: String
  let message: String
  let symbol: String
  let tone: StatusTone
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
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

struct CodeSnippetBlock: View {
  let text: String
  var label: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let label {
        HStack {
          Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
          } label: {
            Label("复制", systemImage: "doc.on.doc")
              .font(.caption2)
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
          .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
      )
    }
  }
}

extension MCPServiceExposureMode {
  var localizedTitle: String {
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
