import AppKit
import BridgeIPC
import BridgeServiceAppCore
import SwiftUI

struct BridgeServiceWorkbenchApprovalTray: View {
  @ObservedObject var model: BridgeServiceAppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("等待本机审批", systemImage: "exclamationmark.shield.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(model.approvals, id: \.approvalID) { approval in
            WorkbenchApprovalCard(model: model, approval: approval)
          }
          ForEach(model.directApprovals, id: \.approvalID) { approval in
            WorkbenchDirectApprovalCard(model: model, approval: approval)
          }
        }
      }
      .frame(height: 220)
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(Color.orange.opacity(0.06))
  }
}

struct WorkbenchApprovalCard: View {
  @ObservedObject var model: BridgeServiceAppModel
  let approval: IPCApprovalSummary

  var body: some View {
    let isResolving = model.isResolvingApproval(approval)
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label(approval.title, systemImage: "shield.lefthalf.filled")
          .font(.caption.weight(.bold))
        Spacer()
        StatusBadge(approval.kind, tone: .warning)
      }

      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 6) {
          Text(approval.summary)
            .font(.caption)

          if let reason = approval.reason {
            Text(reason)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }

          if let displayCommand = approval.displayCommand {
            CodeSnippetBlock(
              text: displayCommand,
              label: approval.kind == "permissions" ? "请求的权限范围" : "即将执行的终端命令"
            )
          }

          if !approval.relativePaths.isEmpty {
            Text("目标文件路径")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.secondary)

            ForEach(approval.relativePaths, id: \.self) { path in
              Text(path)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            }
          }
        }
      }
      .frame(maxHeight: 72)

      Divider()

      HStack(spacing: 8) {
        Button("拒绝", role: .destructive) {
          model.resolveApproval(approval, decision: "deny")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isResolving)
        .accessibilityIdentifier("workbench.approval.\(approval.approvalID).deny")

        Spacer()

        if approval.kind == "task_start" {
          Button {
            model.resolveApproval(approval, decision: "allow")
          } label: {
            if isResolving {
              HStack(spacing: 4) {
                ProgressView()
                  .controlSize(.small)
                Text("正在提交…")
              }
            } else {
              Text("批准启动")
            }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(isResolving)
          .accessibilityIdentifier("workbench.approval.\(approval.approvalID).allow")
        } else {
          Menu {
            ForEach(allowDecisions, id: \.self) { decision in
              Button(decisionLabel(decision)) {
                model.resolveApproval(approval, decision: decision)
              }
            }
          } label: {
            if isResolving {
              Label("正在提交…", systemImage: "hourglass")
            } else {
              Label("选择允许范围", systemImage: "chevron.down")
            }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .disabled(isResolving)
          .accessibilityIdentifier("workbench.approval.\(approval.approvalID).allow")
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
    )
  }

  private var allowDecisions: [String] {
    (approval.decisionOptions ?? ["allow", "deny"]).filter { $0 != "deny" }
  }

  private func decisionLabel(_ decision: String) -> String {
    switch decision {
    case "allow_for_session": "本次会话允许"
    case "allow_similar_commands": "允许此类命令"
    default: "仅本次允许"
    }
  }
}

struct WorkbenchDirectApprovalCard: View {
  let model: BridgeServiceAppModel
  let approval: IPCPendingDirectApproval

  var body: some View {
    let isResolving = model.isResolvingDirectApproval(approval)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "terminal.fill")
          .foregroundStyle(.orange)
        Text("Direct 操作等待批准")
          .font(.caption.weight(.bold))
        Spacer()
        Text(approval.kind)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }

      ScrollView(.vertical) {
        Text(approval.summary)
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 56)

      HStack {
        Text("项目 \(approval.projectID)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Text(approval.createdAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Divider()

      HStack(spacing: 8) {
        Button("拒绝") {
          model.resolveDirectApproval(approval, allow: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isResolving)
        .accessibilityIdentifier("workbench.approval.\(approval.approvalID).deny")

        Spacer()

        Button {
          model.resolveDirectApproval(approval, allow: true)
        } label: {
          if isResolving {
            HStack(spacing: 4) {
              ProgressView()
                .controlSize(.small)
              Text("正在提交…")
            }
          } else {
            Text("仅本次允许")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isResolving)
        .accessibilityIdentifier("workbench.approval.\(approval.approvalID).allow")
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.purple.opacity(0.5), lineWidth: 1)
    )
  }
}
