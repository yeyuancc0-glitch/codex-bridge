import SwiftUI

struct ApprovalsPage: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      PageHeader(
        title: "审批",
        subtitle: "只有本机用户可以决定 Codex 的风险操作",
        refreshAction: { await store.perform(.refresh(.approvals)) }
      )
      LoadStateView(
        state: store.snapshot.approvals,
        retry: { await store.perform(.refresh(.approvals)) }
      ) { page in
        ApprovalQueue(page: page, store: store)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }
}

private struct ApprovalQueue: View {
  let page: ApprovalPagePresentation
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    List {
      Section("等待本机决定") {
        if page.pending.isEmpty {
          Label("当前没有待审批请求", systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
        }
        ForEach(page.pending) { approval in
          approvalRow(approval)
        }
      }
      if !page.resolved.isEmpty {
        Section("最近已处理") {
          ForEach(page.resolved) { approval in
            ApprovalSummaryRow(approval: approval)
          }
        }
      }
    }
    .accessibilityLabel("Codex 审批队列")
  }

  private func approvalRow(_ approval: ApprovalRowPresentation) -> some View {
    HStack(alignment: .top, spacing: BridgeTheme.spacingRegular) {
      ApprovalSummaryRow(approval: approval)
      Spacer()
      Button("查看并决定") {
        guard let detail = page.details.first(where: { $0.id == approval.id }) else { return }
        store.presentCodexApproval(detail)
      }
      .disabled(!page.details.contains(where: { $0.id == approval.id }))
      .help("打开包含命令、cwd、原因与影响范围的审批详情")
    }
  }
}

private struct ApprovalSummaryRow: View {
  let approval: ApprovalRowPresentation

  var body: some View {
    HStack(alignment: .top, spacing: BridgeTheme.spacingRegular) {
      Image(systemName: approval.risk.systemImage)
        .foregroundStyle(approval.risk.tint)
        .frame(width: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
        Text(approval.summary)
          .font(.body.weight(.medium))
        Text("\(approval.source) · \(approval.requestedAt.bridgeFormatted)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(approval.summary)，来源 \(approval.source)，\(approval.risk.accessibilitySummary)"
    )
  }
}

struct ConnectionsPage: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      PageHeader(
        title: "连接",
        subtitle: "检查 ChatGPT、Tunnel、本地 MCP 与两个 Codex 会话边界",
        refreshAction: { await store.perform(.refresh(.connections)) }
      )
      LoadStateView(
        state: store.snapshot.connections,
        retry: { await store.perform(.refresh(.connections)) }
      ) { page in
        ConnectionContent(page: page, store: store)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }
}

private struct ConnectionContent: View {
  let page: ConnectionPagePresentation
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingPage) {
        HStack {
          VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
            Text(page.mode)
              .font(.title3.weight(.semibold))
            Text(page.endpoint)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Spacer()
          Button("测试连接", systemImage: "stethoscope") {
            Task { await store.perform(.testConnection) }
          }
          .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
          SectionHeading("连接路径", detail: "节点状态均来自可验证的本地检查")
          ForEach(page.nodes) { node in
            VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
              StatusRow(title: node.title, detail: node.detail, status: node.status)
              if let checkedAt = node.checkedAt {
                Text("检查时间：\(checkedAt.value.bridgeFormatted) · 来源：\(checkedAt.source)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Divider()
          }
        }
        if let lastError = page.lastError {
          VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
            SectionHeading("最近错误")
            Label(lastError, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
        Toggle(
          "暂停接收新任务",
          isOn: Binding(
            get: { page.receivingPaused },
            set: { value in
              Task { await store.perform(.setReceivingPaused(value)) }
            }
          )
        )
        .help("暂停只影响新提交，不会中断本地正在运行的任务")
      }
      .frame(maxWidth: BridgeTheme.readableTextWidth, alignment: .leading)
    }
  }
}
