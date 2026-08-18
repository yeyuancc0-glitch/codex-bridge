import AppKit
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
      .frame(minWidth: 200)
      .safeAreaInset(edge: .bottom) {
        connectionFooter
      }
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
          ToolbarItem {
            Button {
              model.refresh()
            } label: {
              Label("刷新状态", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
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
    HStack(spacing: 8) {
      Label(item.title, systemImage: item.symbol)

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
        }
      default:
        EmptyView()
      }
    }
    .padding(.vertical, 2)
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
      Circle()
        .fill(footerStatusColor)
        .frame(width: 8, height: 8)

      Text(model.connectionState.label)
        .font(.caption)
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
        .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.4)),
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
