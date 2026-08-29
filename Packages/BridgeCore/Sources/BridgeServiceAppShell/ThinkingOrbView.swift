import SwiftUI
import BridgeServiceAppCore

/// 原生 SwiftUI 动态思考光球组件，参考 `thinking-orbs` 视觉风格。
/// 基于 `TimelineView(.animation)` 与 `Canvas` 硬件加速绘制多层呼吸光核与轨道粒子。
public struct ThinkingOrbView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public var size: CGFloat
  public var primaryColor: Color
  public var secondaryColor: Color
  public var accentColor: Color

  public init(
    size: CGFloat = 22,
    primaryColor: Color = Color(red: 0.0, green: 0.85, blue: 1.0),  // Cyan #00E5FF
    secondaryColor: Color = Color(red: 0.58, green: 0.25, blue: 0.98),  // Violet #9440FA
    accentColor: Color = Color(red: 0.16, green: 0.50, blue: 1.0)  // Blue #2979FF
  ) {
    self.size = size
    self.primaryColor = primaryColor
    self.secondaryColor = secondaryColor
    self.accentColor = accentColor
  }

  public var body: some View {
    Group {
      if reduceMotion {
        orb(time: 0)
      } else {
        TimelineView(.animation) { timeline in
          orb(time: timeline.date.timeIntervalSinceReferenceDate)
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private func orb(time: TimeInterval) -> some View {
    Canvas { context, canvasSize in
      let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
      let baseRadius = min(canvasSize.width, canvasSize.height) * 0.42

      // 1. 外部柔和辉光层 (Outer Aura)
      let auraBreath = 0.85 + 0.15 * sin(time * 2.2)
      let auraRect = CGRect(
        x: center.x - baseRadius * 1.3 * auraBreath,
        y: center.y - baseRadius * 1.3 * auraBreath,
        width: baseRadius * 2.6 * auraBreath,
        height: baseRadius * 2.6 * auraBreath
      )
      context.fill(
        Path(ellipseIn: auraRect),
        with: .radialGradient(
          Gradient(colors: [
            primaryColor.opacity(0.35),
            secondaryColor.opacity(0.18),
            Color.clear,
          ]),
          center: center,
          startRadius: 0,
          endRadius: baseRadius * 1.3 * auraBreath
        )
      )

      // 2. 核心呼吸光球 (Pulsing Core)
      let coreBreath = 0.9 + 0.1 * cos(time * 3.0)
      let coreRect = CGRect(
        x: center.x - baseRadius * coreBreath,
        y: center.y - baseRadius * coreBreath,
        width: baseRadius * 2.0 * coreBreath,
        height: baseRadius * 2.0 * coreBreath
      )
      context.fill(
        Path(ellipseIn: coreRect),
        with: .radialGradient(
          Gradient(colors: [
            .white.opacity(0.85),
            primaryColor.opacity(0.8),
            secondaryColor.opacity(0.6),
            accentColor.opacity(0.0),
          ]),
          center: CGPoint(
            x: center.x + baseRadius * 0.2 * sin(time * 1.8),
            y: center.y - baseRadius * 0.2 * cos(time * 1.8)
          ),
          startRadius: 0,
          endRadius: baseRadius * coreBreath
        )
      )

      // 3. 轨道旋转粒子群 (Orbiting Particles)
      let particleCount = 7
      for i in 0..<particleCount {
        let speed = 1.6 + Double(i) * 0.35
        let phase = Double(i) * (2.0 * .pi / Double(particleCount))
        let orbitAngle = time * speed + phase
        let tilt = Double(i) * 0.45

        let orbitRx = baseRadius * (0.65 + 0.25 * sin(time * 1.2 + Double(i)))
        let orbitRy = baseRadius * (0.35 + 0.2 * cos(time * 1.5 + Double(i)))

        // 旋转倾角变换
        let unrotatedX = orbitRx * cos(orbitAngle)
        let unrotatedY = orbitRy * sin(orbitAngle)

        let cosTilt = cos(tilt)
        let sinTilt = sin(tilt)

        let px = center.x + CGFloat(unrotatedX * cosTilt - unrotatedY * sinTilt)
        let py = center.y + CGFloat(unrotatedX * sinTilt + unrotatedY * cosTilt)

        let pSize = CGFloat(1.6 + 1.2 * sin(time * 4.0 + Double(i)))
        let pRect = CGRect(
          x: px - pSize / 2,
          y: py - pSize / 2,
          width: pSize,
          height: pSize
        )

        let pColor: Color = (i % 3 == 0) ? .white : ((i % 2 == 0) ? primaryColor : secondaryColor)
        let pAlpha = 0.6 + 0.4 * sin(time * 3.0 + phase)

        context.fill(
          Path(ellipseIn: pRect),
          with: .color(pColor.opacity(pAlpha))
        )
      }
    }
  }
}

/// 思考中状态胶囊组件，展示带有生命感的动态光球与状态文字。
public struct ThinkingBubbleView: View {
  public var statusText: String
  public var detailText: String?
  public var isPillStyle: Bool

  public init(
    statusText: String = "Codex 正在思考…",
    detailText: String? = nil,
    isPillStyle: Bool = true
  ) {
    self.statusText = statusText
    self.detailText = detailText
    self.isPillStyle = isPillStyle
  }

  public var body: some View {
    HStack(spacing: 8) {
      ThinkingOrbView(size: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(statusText)
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(.primary)

        if let detailText, !detailText.isEmpty {
          Text(detailText)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
    )
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          LinearGradient(
            colors: [
              Color.cyan.opacity(0.4),
              Color.purple.opacity(0.35),
              Color.blue.opacity(0.2),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 1
        )
    )
    .shadow(color: Color.purple.opacity(0.12), radius: 8, x: 0, y: 2)
  }
}
