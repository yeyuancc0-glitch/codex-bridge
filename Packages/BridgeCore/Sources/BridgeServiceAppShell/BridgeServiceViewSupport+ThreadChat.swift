import AppKit
import BridgeMCP
import SwiftUI

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
            AgentMarkdownText(group.mainText)
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
              AgentMarkdownText(thought)
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
