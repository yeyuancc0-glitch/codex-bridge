import SwiftUI

struct TaskConfirmationSheet: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    if case .taskConfirmation(let confirmation) = store.presentedSheet {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
        sheetHeader(
          title: "确认本机任务",
          subtitle: "开始前核对任务契约、执行模型与权限边界"
        )
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
            contractSection(confirmation)
            executionSection(confirmation)
            scopeSection(confirmation)
            riskSection(confirmation)
          }
          .frame(maxWidth: BridgeTheme.readableTextWidth, alignment: .leading)
        }
        Divider()
        taskDecisionBar(canStart: canStart(confirmation))
      }
      .padding(BridgeTheme.spacingPage)
      .frame(minWidth: 680, minHeight: 620)
      .interactiveDismissDisabled(store.isPerformingSheetAction)
    }
  }

  private func contractSection(_ confirmation: TaskConfirmationPresentation) -> some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("任务契约")
      MetadataRow(label: "项目", value: confirmation.projectName)
      MetadataRow(label: "线程", value: confirmation.threadDescription, monospaced: true)
      Text(confirmation.goal)
        .font(.body.weight(.medium))
        .textSelection(.enabled)
      Text("验收标准")
        .font(.subheadline.weight(.semibold))
      BulletList(items: confirmation.acceptanceCriteria, emptyMessage: "未提供验收标准")
    }
  }

  private func executionSection(_ confirmation: TaskConfirmationPresentation) -> some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("执行设置")
      Picker(
        "执行模型",
        selection: Binding(
          get: { confirmation.executionModel },
          set: { store.updateConfirmationModel($0) }
        )
      ) {
        ForEach(confirmation.availableModels, id: \.self) { model in
          Text(model).tag(model)
        }
      }
      Picker(
        "推理深度",
        selection: Binding(
          get: { confirmation.effort },
          set: { store.updateConfirmationEffort($0) }
        )
      ) {
        ForEach(confirmation.availableEfforts, id: \.self) { effort in
          Text(effort).tag(effort)
        }
      }
      MetadataRow(label: "权限模式", value: confirmation.permissionMode)
      MetadataRow(label: "网络权限", value: confirmation.networkAllowed ? "允许，仍受策略限制" : "关闭")
      MetadataRow(label: "Supervisor", value: confirmation.supervisorModel)
    }
  }

  private func scopeSection(_ confirmation: TaskConfirmationPresentation) -> some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("预计读取范围")
      BulletList(items: confirmation.estimatedReadScope, emptyMessage: "未声明读取范围")
    }
  }

  @ViewBuilder
  private func riskSection(_ confirmation: TaskConfirmationPresentation) -> some View {
    if !confirmation.riskMessages.isEmpty {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
        SectionHeading("风险提示")
        ForEach(confirmation.riskMessages, id: \.self) { risk in
          Label(risk, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .accessibilityLabel("风险：\(risk)")
        }
      }
    }
  }

  private func canStart(_ confirmation: TaskConfirmationPresentation) -> Bool {
    confirmation.availableModels.contains(confirmation.executionModel)
      && confirmation.availableEfforts.contains(confirmation.effort)
  }

  private func taskDecisionBar(canStart: Bool) -> some View {
    HStack {
      if store.isPerformingSheetAction {
        ProgressView("正在记录决定")
          .controlSize(.small)
      }
      Spacer()
      Button("拒绝", role: .destructive) {
        Task { await store.decideTask(.reject) }
      }
      .disabled(store.isPerformingSheetAction)
      Button("仅只读运行") {
        Task { await store.decideTask(.runReadOnly) }
      }
      .disabled(store.isPerformingSheetAction)
      Button("开始") {
        Task { await store.decideTask(.start) }
      }
      .disabled(!canStart || store.isPerformingSheetAction)
    }
  }
}

struct CodexApprovalSheet: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    if case .codexApproval(let approval) = store.presentedSheet {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
        sheetHeader(
          title: "Codex 请求本机审批",
          subtitle: "Supervisor 只能提供只读风险证据，不能代替你允许"
        )
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
            identitySection(approval)
            operationSection(approval)
            reasonSection(approval)
          }
          .frame(maxWidth: BridgeTheme.readableTextWidth, alignment: .leading)
        }
        Divider()
        approvalDecisionBar(canAllow: approval.canAllow)
      }
      .padding(BridgeTheme.spacingPage)
      .frame(minWidth: 680, minHeight: 580)
      .interactiveDismissDisabled(store.isPerformingSheetAction)
    }
  }

  private func identitySection(_ approval: CodexApprovalPresentation) -> some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("请求身份")
      MetadataRow(label: "来源", value: approval.source)
      if let taskID = approval.taskID {
        MetadataRow(label: "Task", value: taskID, monospaced: true)
      }
      MetadataRow(label: "Thread", value: approval.threadID, monospaced: true)
      MetadataRow(label: "Turn", value: approval.turnID, monospaced: true)
      if let operationID = approval.operationID {
        MetadataRow(label: "Operation", value: operationID, monospaced: true)
      }
      MetadataRow(label: "工作目录", value: approval.workingDirectory, monospaced: true)
    }
  }

  private func operationSection(_ approval: CodexApprovalPresentation) -> some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("请求操作", detail: approval.operationTitle)
      if !approval.commandArguments.isEmpty {
        Text("命令参数（按 argv 边界显示）")
          .font(.subheadline.weight(.semibold))
        ForEach(Array(approval.commandArguments.enumerated()), id: \.offset) { index, argument in
          EvidenceText(text: "argv[\(index)] = \(argument)")
        }
      }
      if let fileOperation = approval.fileOperation {
        MetadataRow(label: "文件操作", value: fileOperation, monospaced: true)
      }
    }
  }

  private func reasonSection(_ approval: CodexApprovalPresentation) -> some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
      SectionHeading("原因与影响")
      MetadataRow(label: "Codex 原因", value: approval.reason)
      MetadataRow(label: "Supervisor 风险", value: approval.supervisorRisk)
      BulletList(items: approval.consequences, emptyMessage: "未提供影响范围；不应允许")
      if !approval.canAllow {
        Label("策略已阻止允许此操作", systemImage: "hand.raised.fill")
          .foregroundStyle(.red)
          .accessibilityLabel("安全阻断：策略不允许批准此操作")
      }
    }
  }

  private func approvalDecisionBar(canAllow: Bool) -> some View {
    HStack {
      if store.isPerformingSheetAction {
        ProgressView("正在持久化审批决定")
          .controlSize(.small)
      }
      Spacer()
      Button("拒绝", role: .destructive) {
        Task { await store.decideApproval(.deny) }
      }
      .disabled(store.isPerformingSheetAction)
      Button("仅允许一次") {
        Task { await store.decideApproval(.allowOnce) }
      }
      .disabled(!canAllow || store.isPerformingSheetAction)
    }
  }
}

private func sheetHeader(title: String, subtitle: String) -> some View {
  VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
    Text(title)
      .font(.title2.weight(.semibold))
    Text(subtitle)
      .font(.subheadline)
      .foregroundStyle(.secondary)
  }
  .accessibilityElement(children: .combine)
}
