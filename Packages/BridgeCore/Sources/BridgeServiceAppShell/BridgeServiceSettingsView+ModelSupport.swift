import BridgeServiceAppCore
import SwiftUI

struct BridgeServiceSettingsModelCatalogStatus: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    if let error = model.modelCatalogError {
      VStack(alignment: .leading, spacing: 8) {
        Label("模型目录读取失败", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text(error)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("重试刷新") {
          model.refresh()
        }
      }
    } else {
      Text("尚未读取到 Codex 模型目录，请确保 Codex app-server 正常运行。")
        .foregroundStyle(.secondary)
    }
  }
}

struct BridgeServiceSettingsModelOptions: View {
  @ObservedObject var model: BridgeServiceAppModel
  let selectedID: String?

  @ViewBuilder
  var body: some View {
    if let selectedID,
      !model.models.contains(where: { $0.modelID == selectedID })
    {
      Text("当前设置不可用 · \(selectedID)")
        .tag(selectedID)
    }
    ForEach(model.models, id: \.modelID) { item in
      Text("\(item.displayName) · \(item.modelID)")
        .tag(item.modelID)
    }
  }
}

struct BridgeServiceSettingsEffortOptions: View {
  @ObservedObject var model: BridgeServiceAppModel
  let modelID: String?
  let selectedEffort: String?

  @ViewBuilder
  var body: some View {
    let efforts = model.models.first(where: { $0.modelID == modelID })?.reasoningEfforts ?? []
    if let selectedEffort, !efforts.contains(selectedEffort) {
      Text("当前设置不可用 · \(selectedEffort)")
        .tag(selectedEffort)
    }
    ForEach(efforts, id: \.self) { effort in
      Text("\(reasoningTitle(effort)) · \(effort)")
        .tag(effort)
    }
  }

  private func reasoningTitle(_ effort: String) -> String {
    switch effort.lowercased() {
    case "minimal": "最低"
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    case "xhigh", "extra_high": "极高"
    default: effort
    }
  }
}
