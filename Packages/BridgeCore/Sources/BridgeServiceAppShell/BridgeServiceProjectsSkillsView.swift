import BridgeMCP
import SwiftUI

struct ProjectSkillsSection: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var isExpanded = false

  private static let collapsedLimit = 4
  private let columns = [
    GridItem(.adaptive(minimum: 240), spacing: 8, alignment: .top)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("已发现 Skills")
          .font(.headline)
          .foregroundStyle(.secondary)

        if !model.skills.isEmpty {
          Text("\(model.skills.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        Spacer()

        if model.skills.count > Self.collapsedLimit {
          Button(isExpanded ? "收起" : "查看全部") {
            withAnimation(.easeInOut(duration: 0.2)) {
              isExpanded.toggle()
            }
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
        }

        Button {
          model.refresh()
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(model.isRefreshing)
      }

      if model.skills.isEmpty {
        NativeCard {
          Label("该项目没有发现可用 Skill", systemImage: "sparkles")
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
      } else {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
          ForEach(visibleSkills) { skill in
            skillCard(skill)
          }
        }

        if !isExpanded, hiddenSkillCount > 0 {
          Text("另有 \(hiddenSkillCount) 个 Skill，点击“查看全部”展开。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var visibleSkills: ArraySlice<MCPServiceSkill> {
    model.skills.prefix(isExpanded ? model.skills.count : Self.collapsedLimit)
  }

  private var hiddenSkillCount: Int {
    max(0, model.skills.count - Self.collapsedLimit)
  }

  private func skillCard(_ skill: MCPServiceSkill) -> some View {
    NativeCard {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "sparkles")
          .foregroundStyle(.tint)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(skill.name)
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
            Text(skill.scope.rawValue)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }

          if !skill.description.isEmpty {
            Text(skill.description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(isExpanded ? 2 : 1)
          }

          if !skill.actions.isEmpty {
            Text("动作：\(skill.actions.count) 个")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        Spacer(minLength: 0)
      }
    }
  }
}
