import AppKit
import SwiftUI
import BridgeServiceAppCore

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
