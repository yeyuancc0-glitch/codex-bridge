import AppKit
import BridgeMCP
import SwiftUI

struct BridgeServiceConnectionsView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SectionHeader(
          "连接",
          subtitle: "后台 Service 持有 MCP、Codex 和 Supervisor；关闭 App 不会停止任务。"
        )

        serviceSection
        Divider()
        mcpSection
        Divider()
        tunnelSection
      }
      .padding(24)
      .frame(maxWidth: 900, alignment: .leading)
    }
    .navigationTitle("连接")
  }

  private var serviceSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("后台 Service")
        .font(.headline)
      LabeledContent("系统注册", value: registrationLabel)
      LabeledContent("XPC", value: model.connectionState.label)

      switch model.registrationStatus {
      case .notRegistered:
        Button("注册后台 Service") {
          model.registerService()
        }
        .buttonStyle(.borderedProminent)
      case .requiresApproval:
        Label(
          "macOS 已记录后台项目，但需要你在登录项设置中批准。",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        Button("打开登录项设置") {
          model.openSystemSettings()
        }
      case .notFound:
        Label(
          "App Bundle 中没有找到 LaunchAgent 配置。请重新构建或安装 App。",
          systemImage: "xmark.circle.fill"
        )
        .foregroundStyle(.red)
      case .enabled:
        Label("后台 Service 已启用。", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
    }
  }

  private var mcpSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("本地 MCP")
        .font(.headline)
      LabeledContent("状态", value: model.serviceStatus?.status.mcpState ?? "未知")
      LabeledContent("工具权限", value: model.exposureMode.localizedTitle)
      if let localMCPURL = model.safeLocalMCPDescription {
        LabeledContent("本机地址") {
          Text(localMCPURL)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        Text("这个地址只供本机诊断，ChatGPT 网页不能直接访问 localhost。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Picker(
        "MCP 工具权限",
        selection: Binding(
          get: { model.exposureMode },
          set: { model.setExposureMode($0) }
        )
      ) {
        Text("只读").tag(MCPServiceExposureMode.readOnly)
        Text("完整操作").tag(MCPServiceExposureMode.full)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 360)

      Text(
        model.exposureMode == .full
          ? "完整操作会向 ChatGPT 暴露任务提交、纠偏和中断工具；所有任务和 Codex 权限仍需本机批准。"
          : "只读模式只允许查询项目、文件、Thread、模型和任务状态。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var tunnelSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("远程 Tunnel")
        .font(.headline)
      LabeledContent(
        "状态",
        value: model.serviceStatus?.status.tunnelState ?? "未配置"
      )
      Text(
        "Secure MCP Tunnel 仍需迁入后台 Service。完成后，这里会显示远程地址、健康状态和认证配置。"
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var registrationLabel: String {
    switch model.registrationStatus {
    case .notRegistered: "未注册"
    case .enabled: "已启用"
    case .requiresApproval: "等待批准"
    case .notFound: "配置缺失"
    }
  }
}

struct BridgeServiceSettingsView: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    Form {
      Section("模型目录") {
        if model.models.isEmpty {
          Text("尚未读取到 Codex 模型目录。")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.models, id: \.modelID) { item in
            LabeledContent(item.displayName) {
              VStack(alignment: .trailing, spacing: 2) {
                Text(item.modelID)
                  .font(.caption.monospaced())
                Text(item.reasoningEfforts.joined(separator: ", "))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      Section("后台运行") {
        LabeledContent("注册状态", value: registrationLabel)
        Button("打开 macOS 登录项设置") {
          model.openSystemSettings()
        }
        Button("停用后台 Service", role: .destructive) {
          Task { await model.disableBackgroundService() }
        }
        .disabled(model.registrationStatus == .notRegistered)
      }

      Section("说明") {
        Text(
          "退出可视化 App 只会断开本机 XPC 客户端，不会主动停止后台 Service、Codex 或 Supervisor。"
        )
        Text(
          "只有“停用后台 Service”属于明确的后台停止操作。正在执行任务时不建议使用。"
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding(20)
    .navigationTitle("设置")
  }

  private var registrationLabel: String {
    switch model.registrationStatus {
    case .notRegistered: "未注册"
    case .enabled: "已启用"
    case .requiresApproval: "等待批准"
    case .notFound: "配置缺失"
    }
  }
}
