import SwiftUI

public struct BridgeRootView: View {
  @ObservedObject private var store: BridgePresentationStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(store: BridgePresentationStore) {
    self.store = store
  }

  public var body: some View {
    NavigationSplitView {
      List(BridgeNavigationDestination.allCases, selection: $store.destination) { destination in
        Label(destination.title, systemImage: destination.systemImage)
          .tag(destination)
          .accessibilityLabel(destination.title)
      }
      .navigationTitle("Codex Bridge")
      .listStyle(.sidebar)
      .frame(minWidth: 180)
    } detail: {
      destinationView
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.destination)
    }
    .navigationSplitViewStyle(.balanced)
    .sheet(item: sheetBinding) { sheet in
      switch sheet {
      case .taskConfirmation:
        TaskConfirmationSheet(store: store)
      case .codexApproval:
        CodexApprovalSheet(store: store)
      }
    }
    .alert(
      store.actionError?.title ?? "操作未完成",
      isPresented: actionErrorBinding,
      presenting: store.actionError
    ) { _ in
      Button("好") { store.actionError = nil }
    } message: { error in
      Text(error.message)
    }
  }

  @ViewBuilder
  private var destinationView: some View {
    switch store.destination {
    case .overview:
      OverviewPage(store: store)
    case .tasks:
      TasksPage(store: store)
    case .projects:
      ProjectsPage(store: store)
    case .threads:
      ThreadsPage(store: store)
    case .approvals:
      ApprovalsPage(store: store)
    case .connections:
      ConnectionsPage(store: store)
    case .logs:
      LogsPage(store: store)
    case .settings:
      SettingsPage(store: store)
    }
  }

  private var sheetBinding: Binding<PresentedBridgeSheet?> {
    Binding(
      get: { store.presentedSheet },
      set: { value in
        if value == nil { store.dismissSheet() }
      }
    )
  }

  private var actionErrorBinding: Binding<Bool> {
    Binding(
      get: { store.actionError != nil },
      set: { value in
        if !value { store.actionError = nil }
      }
    )
  }
}
