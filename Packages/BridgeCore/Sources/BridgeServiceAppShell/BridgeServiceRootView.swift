import AppKit
import BridgeServiceAppCore
import SwiftUI

public struct BridgeServiceRootView: View {
  @ObservedObject private var model: BridgeServiceAppModel

  public init(model: BridgeServiceAppModel) {
    self.model = model
  }

  public var body: some View {
    NavigationSplitView {
      List(BridgeServiceNavigation.allCases, id: \.self, selection: $model.selection) { item in
        NavigationLink(value: item) {
          sidebarRow(for: item)
        }
      }
      .navigationTitle("Codex Bridge")
      .listStyle(.sidebar)
      .frame(minWidth: 220)
      .safeAreaInset(edge: .bottom) {
        connectionFooter
      }
    } detail: {
      ZStack(alignment: .bottomTrailing) {
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let toast = model.toast {
          ToastHUDView(toast: toast) {
            model.clearToast()
          }
          .padding(.trailing, 24)
          .padding(.bottom, 20)
          .zIndex(100)
        }
      }
      .toolbar {
        ToolbarItem(placement: .automatic) {
          Button {
            model.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
              .rotationEffect(model.isRefreshing ? .degrees(360) : .degrees(0))
              .animation(
                model.isRefreshing
                  ? .linear(duration: 1).repeatForever(autoreverses: false)
                  : .default,
                value: model.isRefreshing
              )
          }
          .disabled(model.isRefreshing)
          .accessibilityLabel("刷新状态")
          .help("刷新后台 Service、项目、Skills 及连接状态")
        }
      }
    }
    .task {
      model.start()
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { visible in
          if !visible { model.errorMessage = nil }
        }
      )
    ) {
      Button("好", role: .cancel) {
        model.errorMessage = nil
      }
    } message: {
      Text(model.errorMessage ?? "未知错误")
    }
  }

  @ViewBuilder
  private func sidebarRow(for item: BridgeServiceNavigation) -> some View {
    HStack(spacing: 10) {
      Label(item.title, systemImage: item.symbol)
        .font(.system(size: 13, weight: .medium))

      Spacer(minLength: 4)

      switch item {
      case .workbench:
        if !model.approvals.isEmpty {
          Text("\(model.approvals.count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange)
            .clipShape(Capsule())
        } else if model.runningTaskCount > 0 {
          Text("\(model.runningTaskCount)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green)
            .clipShape(Capsule())
        }
      case .projects:
        if !model.projects.isEmpty {
          Text("\(model.projects.count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
      default:
        EmptyView()
      }
    }
    .padding(.vertical, 3)
  }

  @ViewBuilder
  private var detail: some View {
    switch model.selection ?? .overview {
    case .overview:
      BridgeServiceOverviewView(model: model)
    case .workbench:
      BridgeServiceWorkbenchView(model: model)
    case .projects:
      BridgeServiceProjectsView(model: model)
    case .logs:
      BridgeServiceLogsView(model: model)
    case .connections:
      BridgeServiceConnectionsView(model: model)
    case .settings:
      BridgeServiceSettingsView(model: model)
    }
  }

  private var connectionFooter: some View {
    HStack(spacing: 8) {
      ZStack {
        Circle()
          .fill(footerStatusColor.opacity(0.25))
          .frame(width: 14, height: 14)
        Circle()
          .fill(footerStatusColor)
          .frame(width: 8, height: 8)
      }

      Text(model.connectionState.label)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary)

      Spacer(minLength: 0)

      if model.isRefreshing {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
    .overlay(
      Rectangle()
        .frame(height: 0.5)
        .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.35)),
      alignment: .top
    )
  }

  private var footerStatusColor: Color {
    switch model.connectionState {
    case .connected: .green
    case .registering, .connecting: .orange
    case .requiresApproval: .orange
    case .idle, .unavailable: .red
    }
  }
}

public struct BridgeServiceMenuBarView: View {
  @ObservedObject private var model: BridgeServiceAppModel

  public init(model: BridgeServiceAppModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Circle()
          .fill(menuStatusColor)
          .frame(width: 8, height: 8)
        Text("Codex Bridge · \(model.connectionState.label)")
          .font(.subheadline.weight(.semibold))
      }

      if model.runningTaskCount > 0 {
        Label("正在运行 \(model.runningTaskCount) 个任务", systemImage: "bolt.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }

      if model.approvals.count > 0 {
        Label("等待处理 \(model.approvals.count) 项安全审批", systemImage: "exclamationmark.shield.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      Divider()

      Button("打开工作台") {
        model.selection = .workbench
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
      }

      Button("打开主窗口") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
      }

      Button("立即刷新状态") {
        model.refresh()
      }

      Divider()

      Button("退出应用程序") {
        NSApp.terminate(nil)
      }
    }
    .padding(10)
    .task {
      model.start()
    }
  }

  private var menuStatusColor: Color {
    switch model.connectionState {
    case .connected: .green
    case .registering, .connecting: .orange
    case .requiresApproval: .orange
    case .idle, .unavailable: .red
    }
  }
}
