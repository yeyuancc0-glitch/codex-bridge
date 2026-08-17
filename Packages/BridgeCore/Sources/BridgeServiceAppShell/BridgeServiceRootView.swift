import AppKit
import SwiftUI

public struct BridgeServiceRootView: View {
  @ObservedObject private var model: BridgeServiceAppModel

  public init(model: BridgeServiceAppModel) {
    self.model = model
  }

  public var body: some View {
    NavigationSplitView {
      List(BridgeServiceNavigation.allCases, selection: $model.selection) { item in
        Label(item.title, systemImage: item.symbol)
          .tag(Optional(item))
      }
      .navigationTitle("Codex Bridge")
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
              Label("刷新", systemImage: "arrow.clockwise")
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
  private var detail: some View {
    switch model.selection ?? .overview {
    case .overview:
      BridgeServiceOverviewView(model: model)
    case .tasks:
      BridgeServiceTasksView(model: model)
    case .projects:
      BridgeServiceProjectsView(model: model)
    case .connections:
      BridgeServiceConnectionsView(model: model)
    case .settings:
      BridgeServiceSettingsView(model: model)
    }
  }

  private var connectionFooter: some View {
    HStack(spacing: 8) {
      Image(systemName: model.connectionState.symbol)
        .accessibilityHidden(true)
      Text(model.connectionState.label)
        .font(.caption)
      Spacer(minLength: 0)
      if model.isRefreshing {
        ProgressView()
          .controlSize(.small)
      }
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.bar)
  }
}

public struct BridgeServiceMenuBarView: View {
  @ObservedObject private var model: BridgeServiceAppModel

  public init(model: BridgeServiceAppModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(model.connectionState.label, systemImage: model.connectionState.symbol)
      if model.runningTaskCount > 0 {
        Text("正在运行 \(model.runningTaskCount) 个任务")
      }
      if model.approvals.count > 0 || model.pendingLocalTaskCount > 0 {
        Text("需要处理 \(model.approvals.count + model.pendingLocalTaskCount) 项")
      }
      Divider()
      Button("打开 Codex Bridge") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
      }
      Button("刷新状态") {
        model.refresh()
      }
      Divider()
      Button("退出") {
        NSApp.terminate(nil)
      }
    }
    .padding(8)
    .task {
      model.start()
    }
  }
}
