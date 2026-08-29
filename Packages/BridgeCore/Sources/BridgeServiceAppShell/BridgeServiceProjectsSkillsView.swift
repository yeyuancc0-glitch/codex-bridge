import BridgeMCP
import SwiftUI
import BridgeServiceAppCore

struct ProjectSkillsSection: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var isExpanded = false

  private static let collapsedLimit = 4
  private let columns = [
    GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("已发现 Skills")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)

        if !model.skills.isEmpty {
          Text("\(model.skills.count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }

        Spacer()

        if model.skills.count > Self.collapsedLimit {
          Button(isExpanded ? "收起" : "查看全部 (\(model.skills.count))") {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
              isExpanded.toggle()
            }
          }
          .buttonStyle(.borderless)
          .font(.caption.weight(.medium))
        }

        Button {
          model.refresh()
          model.postToast("已重新扫描项目 Skills", symbol: "sparkles")
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
              .rotationEffect(model.isRefreshing ? .degrees(360) : .degrees(0))
              .animation(
                model.isRefreshing
                  ? .linear(duration: 1).repeatForever(autoreverses: false)
                  : .default,
                value: model.isRefreshing
              )
            Text("刷新")
          }
        }
        .buttonStyle(.borderless)
        .font(.caption.weight(.medium))
        .disabled(model.isRefreshing)
      }

      if model.skills.isEmpty {
        NativeCard {
          HStack(spacing: 10) {
            Image(systemName: "sparkles")
              .foregroundStyle(.secondary)
            Text("该项目或用户目录下没有发现可用 Skill。在项目根或 .gemini 放置 SKILL.md 即可自动识别。")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 6)
        }
      } else {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
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
      HStack(alignment: .top, spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.purple.opacity(0.12))
            .frame(width: 32, height: 32)
          Image(systemName: "sparkles")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.purple)
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(skill.name)
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)

            StatusBadge(skill.scope.rawValue, tone: .neutral)
          }

          if !skill.description.isEmpty {
            Text(skill.description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(isExpanded ? 3 : 1)
          }

          if !skill.actions.isEmpty {
            HStack(spacing: 4) {
              Image(systemName: "bolt.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
              Text(
                "\(skill.actions.count) 个动作：\(skill.actions.prefix(2).map(\.name).joined(separator: "、"))\(skill.actions.count > 2 ? "…" : "")"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
          }
        }

        Spacer(minLength: 0)
      }
    }
  }
}
