import SwiftUI

struct LogsPage: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      PageHeader(
        title: "日志",
        subtitle: "读取脱敏诊断事实，不包含密钥或文件全文",
        refreshAction: { await store.perform(.refresh(.logs)) }
      )
      HStack {
        if case .ready(let page) = store.snapshot.logs, page.isStreaming {
          Label("正在接收新日志", systemImage: "dot.radiowaves.left.and.right")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("导出脱敏支持包", systemImage: "square.and.arrow.up") {
          Task { await store.perform(.exportSupportBundle) }
        }
        .disabled(!logExportIsAvailable)
        .help(logExportIsAvailable ? "导出脱敏诊断事实" : "支持包导出尚未接通")
      }
      LoadStateView(
        state: store.snapshot.logs,
        retry: { await store.perform(.refresh(.logs)) }
      ) { page in
        LogList(page: page)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }

  private var logExportIsAvailable: Bool {
    guard case .ready(let page) = store.snapshot.logs else { return false }
    return page.canExport
  }
}

private struct LogList: View {
  let page: LogPagePresentation

  @ViewBuilder
  var body: some View {
    if page.entries.isEmpty {
      ContentUnavailableView(
        "暂无诊断日志",
        systemImage: "doc.text.magnifyingglass",
        description: Text("发生可诊断事件后，脱敏日志会显示在这里。")
      )
    } else {
      List(page.entries) { entry in
        HStack(alignment: .firstTextBaseline, spacing: BridgeTheme.spacingRegular) {
          Text(entry.timestamp.bridgeFormatted)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 132, alignment: .leading)
          Label(entry.severity.label, systemImage: entry.severity.systemImage)
            .labelStyle(.iconOnly)
            .foregroundStyle(entry.severity.tint)
            .frame(width: 20)
          Text(entry.source)
            .font(.system(.caption, design: .monospaced))
            .frame(width: 110, alignment: .leading)
          Text(entry.message)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(entry.timestamp.bridgeFormatted)，\(entry.source)，\(entry.severity.accessibilitySummary)，\(entry.message)"
        )
      }
      .accessibilityLabel("脱敏诊断日志")
    }
  }
}

struct SettingsPage: View {
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingSection) {
      PageHeader(
        title: "设置",
        subtitle: "全局启动、通知、安全和保留策略",
        refreshAction: { await store.perform(.refresh(.settings)) }
      )
      LoadStateView(
        state: store.snapshot.settings,
        retry: { await store.perform(.refresh(.settings)) }
      ) { page in
        SettingsForm(page: page, store: store)
      }
    }
    .padding(BridgeTheme.spacingPage)
  }
}

private struct SettingsForm: View {
  let page: SettingsPagePresentation
  @ObservedObject var store: BridgePresentationStore

  var body: some View {
    Form {
      settingSection("通用", settings: page.general)
      settingSection("通知", settings: page.notifications)
      settingSection("安全", settings: page.security)
      Section("保留策略") {
        LabeledContent("当前策略", value: page.retentionSummary)
        Stepper(
          "事件保留 \(page.retentionPolicy.eventDays) 天",
          value: eventDaysBinding,
          in: 1...3_650
        )
        Stepper(
          "元数据保留 \(page.retentionPolicy.metadataDays) 天",
          value: metadataDaysBinding,
          in: max(page.retentionPolicy.eventDays, 1)...3_650
        )
        LabeledContent(
          "最近任务",
          value: page.retentionPolicy.recentTaskLimit.map(String.init) ?? "不额外限制"
        )
      }
      Section("备份与恢复") {
        LabeledContent("最近备份", value: page.backupSummary)
        LabeledContent("恢复状态", value: page.restoreSummary)
        HStack {
          Button("导出备份…", systemImage: "externaldrive.badge.plus") {
            Task { await store.perform(.exportBackup) }
          }
          .disabled(!page.canExportBackup)
          .help(page.canExportBackup ? "导出三份 SQLite 的一致快照" : "存在待应用恢复或活动任务时不能导出")
          Button("恢复备份…", systemImage: "arrow.counterclockwise") {
            Task { await store.perform(.restoreBackup) }
          }
          .disabled(!page.canRestoreBackup)
          .help(page.canRestoreBackup ? "选择备份包；校验后退出应用，重新打开时完成恢复" : "已存在待应用恢复时不能再次恢复")
        }
        Text("恢复会先校验备份包，再由应用退出重启完成原子替换；期间不会改动当前数据。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func settingSection(
    _ title: String,
    settings: [SettingTogglePresentation]
  ) -> some View {
    Section(title) {
      ForEach(settings) { setting in
        Toggle(
          isOn: Binding(
            get: { setting.isOn },
            set: { value in
              Task { await store.perform(.updateSetting(key: setting.id, enabled: value)) }
            }
          )
        ) {
          VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
            Text(setting.title)
            Text(setting.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .disabled(!setting.isEnabled)
      }
    }
  }

  private var eventDaysBinding: Binding<Int> {
    Binding(
      get: { page.retentionPolicy.eventDays },
      set: { value in
        let policy = page.retentionPolicy
        Task {
          await store.perform(
            .updateRetentionPolicy(
              eventDays: min(max(value, 1), 3_650),
              metadataDays: max(policy.metadataDays, min(max(value, 1), 3_650)),
              recentTaskLimit: policy.recentTaskLimit,
              expectedRevision: policy.revision
            )
          )
        }
      }
    )
  }

  private var metadataDaysBinding: Binding<Int> {
    Binding(
      get: { page.retentionPolicy.metadataDays },
      set: { value in
        let policy = page.retentionPolicy
        Task {
          await store.perform(
            .updateRetentionPolicy(
              eventDays: policy.eventDays,
              metadataDays: min(max(value, policy.eventDays), 3_650),
              recentTaskLimit: policy.recentTaskLimit,
              expectedRevision: policy.revision
            )
          )
        }
      }
    )
  }
}
