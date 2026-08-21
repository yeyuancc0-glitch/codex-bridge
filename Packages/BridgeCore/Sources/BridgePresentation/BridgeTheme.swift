import SwiftUI

public enum BridgeTheme {
  public static let spacingTight: CGFloat = 4
  public static let spacingRegular: CGFloat = 8
  public static let spacingSection: CGFloat = 16
  public static let spacingPage: CGFloat = 24
  public static let compactCornerRadius: CGFloat = 8
  public static let readableTextWidth: CGFloat = 720
}

extension PresentationStatus {
  var tint: Color {
    switch self {
    case .ready, .completed: .green
    case .waiting, .degraded: .orange
    case .disconnected, .blocked, .failed: .red
    case .checking, .running: .blue
    case .paused: .secondary
    }
  }
}
