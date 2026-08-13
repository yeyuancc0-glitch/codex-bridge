import BridgeAppModel
import BridgePresentation
import SwiftUI

public struct BridgeDesktopRootView: View {
  @ObservedObject private var runtime: BridgeDesktopRuntime

  public init(runtime: BridgeDesktopRuntime) {
    self.runtime = runtime
  }

  public var body: some View {
    BridgeRootView(store: runtime.presentationStore)
      .frame(minWidth: 760, minHeight: 520)
      .task { runtime.start() }
  }
}

public struct BridgeMenuBarView: View {
  @ObservedObject private var runtime: BridgeDesktopRuntime
  @ObservedObject private var appModel: BridgeAppModel

  public init(runtime: BridgeDesktopRuntime) {
    self.runtime = runtime
    _appModel = ObservedObject(wrappedValue: runtime.appModel)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(statusTitle, systemImage: statusSymbol)
        .font(.headline)
      Text(statusDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
      Divider()
      Button("打开 Codex Bridge", systemImage: "macwindow") {
        runtime.showMainWindow()
      }
      Button("退出", systemImage: "power") {
        runtime.terminateApplication()
      }
      .keyboardShortcut("q")
    }
    .padding(10)
    .frame(width: 250, alignment: .leading)
  }

  private var statusTitle: String {
    switch appModel.lifecycleState {
    case .stopped: "Bridge 已停止"
    case .starting: "Bridge 正在启动"
    case .running(_, let connection): connectionTitle(connection)
    case .failed: "Bridge 启动失败"
    }
  }

  private var statusDetail: String {
    switch appModel.lifecycleState {
    case .stopped: "打开主窗口以启动本机状态读取。"
    case .starting: "正在安全打开持久化数据。"
    case .running(_, .ready): "ChatGPT 连接已就绪。"
    case .running: "本机应用可用；远程连接尚未配置。"
    case .failed: "打开主窗口查看可恢复的错误。"
    }
  }

  private var statusSymbol: String {
    switch appModel.lifecycleState {
    case .stopped: "pause.circle"
    case .starting: "arrow.triangle.2.circlepath"
    case .running(_, .ready): "checkmark.circle.fill"
    case .running: "link.badge.plus"
    case .failed: "xmark.octagon.fill"
    }
  }

  private func connectionTitle(_ connection: BridgeAppConnectionState) -> String {
    switch connection {
    case .stopped: "连接尚未配置"
    case .starting: "连接正在启动"
    case .authenticating: "正在验证连接"
    case .connecting: "正在连接 ChatGPT"
    case .ready: "Bridge 已连接"
    case .degraded: "Bridge 部分降级"
    case .failed: "连接失败"
    }
  }
}
