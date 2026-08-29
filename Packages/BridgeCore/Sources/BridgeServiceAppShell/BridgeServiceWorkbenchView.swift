import SwiftUI
import BridgeServiceAppCore

struct BridgeServiceWorkbenchView: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var isInspectorVisible = true
  @State private var steerInput = ""

  var body: some View {
    HSplitView {
      BridgeServiceWorkbenchBrowserPane(model: model)
        .frame(minWidth: 320, maxWidth: .infinity)

      if isInspectorVisible {
        BridgeServiceWorkbenchInspectorPane(
          model: model,
          steerInput: $steerInput,
          pendingApprovalIDs: pendingApprovalIDs
        )
        .frame(minWidth: 280, idealWidth: 400, maxWidth: .infinity)
      }
    }
    .frame(minHeight: 0, maxHeight: .infinity)
    .navigationTitle("工作台")
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            isInspectorVisible.toggle()
          }
        } label: {
          Label(
            isInspectorVisible ? "隐藏右侧面板" : "显示右侧面板",
            systemImage: isInspectorVisible ? "sidebar.right" : "sidebar.right"
          )
        }
        .help(isInspectorVisible ? "收起右侧实时监控面板" : "展开右侧实时监控面板")
        .disabled(!pendingApprovalIDs.isEmpty)
      }
    }
    .task {
      if model.selectedProjectID == nil, let pID = model.projects.first?.projectID {
        model.selectProject(pID)
      }
    }
    .onChange(of: pendingApprovalIDs) { previous, current in
      guard WorkbenchApprovalPresentation.shouldReveal(previous: previous, current: current)
      else { return }
      withAnimation(.easeInOut(duration: 0.2)) {
        isInspectorVisible = true
      }
    }
  }

  private var pendingApprovalIDs: [String] {
    model.approvals.map { "codex:\($0.approvalID)" }
      + model.directApprovals.map { "direct:\($0.approvalID)" }
  }
}
