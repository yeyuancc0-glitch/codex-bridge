import AppKit
import BridgeMCP
import SwiftUI
import BridgeServiceAppCore

struct BridgeServiceLogsView: View {
  @ObservedObject var model: BridgeServiceAppModel
  @State private var filterProjectID: String? = nil
  @State private var searchText = ""
  @State private var selectedKind: String = "all"
  @State private var isLogsCopied = false

  var body: some View {
    VStack(spacing: 0) {
      filterToolbar
      Divider()
      logContent
    }
    .navigationTitle("日志")
  }

  private var filterToolbar: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionHeader(
          "执行日志",
          subtitle: "汇总各任务的实时事件、命令执行与文件变更记录。",
          icon: "list.dash.header.rectangle"
        )
        Spacer()

        Button {
          copyAllLogs()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: isLogsCopied ? "checkmark" : "doc.on.doc")
            Text(isLogsCopied ? "已复制" : "复制日志")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(flattenedEvents.isEmpty)

        Button {
          model.refresh()
          model.postToast("已刷新最新日志记录")
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
              .rotationEffect(model.isRefreshing ? .degrees(360) : .degrees(0))
              .animation(
                model.isRefreshing
                  ? .linear(duration: 1).repeatForever(autoreverses: false)
                  : .default,
                value: model.isRefreshing
              )
            Text("刷新")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isRefreshing)
      }

      HStack(spacing: 12) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("搜索日志摘要、命令或文件…", text: $searchText)
            .font(.system(size: 12))
            .textFieldStyle(.plain)
          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.8)
        )
        .frame(maxWidth: 280)

        if model.projects.count > 1 {
          Picker("项目", selection: $filterProjectID) {
            Text("全部项目").tag(String?.none)
            ForEach(model.projects, id: \.projectID) { project in
              Text(project.name).tag(String?.some(project.projectID))
            }
          }
          .pickerStyle(.menu)
          .controlSize(.small)
          .frame(maxWidth: 160)
        }

        Picker("类型", selection: $selectedKind) {
          Text("全部").tag("all")
          Text("命令").tag("command")
          Text("文件").tag("file")
          Text("其他").tag("other")
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(maxWidth: 220)

        Spacer()

        Text("共 \(filteredEvents.count) 条记录")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.1))
          .clipShape(Capsule())
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var logContent: some View {
    if filteredEvents.isEmpty {
      ContentUnavailableView(
        searchText.isEmpty ? "暂无日志事件" : "无匹配日志",
        systemImage: "doc.text.magnifyingglass",
        description: Text(
          searchText.isEmpty ? "当 MCP 客户端或 Codex 执行任务时，事件流会实时记录在此。" : "尝试更换搜索关键字或项目筛选。")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(filteredEvents, id: \.id) { log in
            logRow(log)
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }
    }
  }

  private func logRow(_ log: LogItem) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Text("#\(log.sequence)")
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: 42, alignment: .trailing)

      HStack(spacing: 4) {
        Image(systemName: "folder")
          .font(.caption2)
        Text(log.projectName)
          .font(.system(size: 11, weight: .medium))
          .lineLimit(1)
      }
      .foregroundStyle(.blue)
      .frame(width: 110, alignment: .leading)

      StatusBadge(log.kindBadge.0, symbol: log.kindBadge.1, tone: log.kindBadge.2)
        .frame(width: 64, alignment: .leading)

      Text(log.summary)
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      Spacer(minLength: 0)

      Text(log.timestamp)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: 80, alignment: .trailing)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 0.8)
    )
  }

  private struct LogItem: Identifiable {
    let id: String
    let sequence: Int64
    let taskID: String
    let projectName: String
    let projectID: String
    let summary: String
    let timestamp: String
    let kind: String

    var kindBadge: (String, String, StatusTone) {
      if summary.contains("command") || summary.contains("exec") || summary.contains("run") {
        return ("命令", "terminal", .info)
      } else if summary.contains("file") || summary.contains("edit") || summary.contains("write") {
        return ("文件", "doc.badge.gearshape", .running)
      } else if summary.contains("failed") || summary.contains("error") {
        return ("错误", "xmark.circle.fill", .error)
      } else {
        return ("事件", "circle.fill", .neutral)
      }
    }
  }

  private var flattenedEvents: [LogItem] {
    var items: [LogItem] = []
    for task in model.tasks {
      let pName = model.projectName(for: task.projectID)
      for event in task.recentEvents {
        items.append(
          LogItem(
            id: "\(task.taskID)_\(event.sequence)",
            sequence: event.sequence,
            taskID: task.taskID,
            projectName: pName,
            projectID: task.projectID,
            summary: event.summary,
            timestamp: task.updatedAt,
            kind: event.kind
          )
        )
      }
    }
    return items.sorted(by: { $0.sequence > $1.sequence })
  }

  private var filteredEvents: [LogItem] {
    flattenedEvents.filter { item in
      if let filterProjectID, item.projectID != filterProjectID {
        return false
      }
      if selectedKind == "command" && item.kindBadge.0 != "命令" {
        return false
      }
      if selectedKind == "file" && item.kindBadge.0 != "文件" {
        return false
      }
      if !searchText.isEmpty {
        let q = searchText.lowercased()
        return item.summary.lowercased().contains(q) || item.projectName.lowercased().contains(q)
      }
      return true
    }
  }

  private func copyAllLogs() {
    let count = filteredEvents.count
    let text = filteredEvents.map { "#\($0.sequence) [\($0.projectName)] \($0.summary)" }.joined(
      separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
      isLogsCopied = true
    }
    model.postToast("已复制 \(count) 条日志记录", symbol: "doc.on.doc")
    Task {
      try? await Task.sleep(for: .seconds(2))
      withAnimation(.easeInOut(duration: 0.2)) {
        isLogsCopied = false
      }
    }
  }
}
