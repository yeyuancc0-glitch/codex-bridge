import AppKit
import SwiftUI
import BridgeServiceAppCore

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
