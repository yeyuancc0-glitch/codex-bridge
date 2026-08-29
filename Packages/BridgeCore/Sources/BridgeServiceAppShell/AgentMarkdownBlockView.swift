import SwiftUI
import BridgeServiceAppCore

struct AgentMarkdownTableLayout: Equatable, Sendable {
  let columnCount: Int
  let rowCount: Int
  let alignments: [AgentMarkdownTableAlignment]

  init(
    headers: [String],
    rows: [[String]],
    alignments: [AgentMarkdownTableAlignment]
  ) {
    columnCount = headers.count
    rowCount = rows.count + (headers.isEmpty ? 0 : 1)
    self.alignments = Array(alignments.prefix(headers.count))
  }
}

struct AgentMarkdownDocumentView: View {
  let document: AgentMarkdownDocument
  let isStreaming: Bool
  let fillsWidth: Bool

  var body: some View {
    let lastBlockID = document.blocks.last?.id
    VStack(alignment: .leading, spacing: 10) {
      ForEach(document.blocks) { block in
        AgentMarkdownBlockView(
          block: block,
          showsCursor: isStreaming && block.id == lastBlockID,
          fillsWidth: fillsWidth
        )
      }
      if document.blocks.isEmpty, isStreaming {
        Text("▍")
          .foregroundStyle(.tint)
      }
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
  }
}

struct AgentMarkdownBlockView: View {
  let block: AgentMarkdownBlock
  let showsCursor: Bool
  let fillsWidth: Bool

  var body: some View {
    switch block.content {
    case .paragraph(let text):
      AgentMarkdownInlineText(text, showsCursor: showsCursor)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    case .heading(let level, let text):
      heading(text: text, level: level)
    case .unorderedList(let items):
      list(items: items, ordered: false)
    case .orderedList(let items):
      list(items: items, ordered: true)
    case .quote(let text):
      quote(text)
    case .code(let language, let text):
      code(language: language, text: text)
    case .table(let headers, let rows, let alignments):
      table(headers: headers, rows: rows, alignments: alignments)
    case .thematicBreak:
      Divider()
    }
  }

  private func heading(text: String, level: Int) -> some View {
    AgentMarkdownInlineText(text, showsCursor: showsCursor)
      .font(headingFont(for: level))
      .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
  }

  private func list(items: [String], ordered: Bool) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .top, spacing: 8) {
          Text(ordered ? "\(index + 1)." : "•")
            .font(.body.weight(.medium))
            .frame(width: ordered ? 24 : 12, alignment: .trailing)
          AgentMarkdownInlineText(
            item,
            showsCursor: showsCursor && index == items.count - 1
          )
          .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        }
      }
    }
    .padding(.leading, 4)
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
  }

  private func quote(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 9) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(Color.accentColor.opacity(0.45))
        .frame(width: 3)
      AgentMarkdownInlineText(text, showsCursor: showsCursor)
        .foregroundStyle(.secondary)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }
    .padding(.vertical, 2)
    .padding(.leading, 2)
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
  }

  private func code(language: String?, text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let language, !language.isEmpty {
        Text(language)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      Text(text + (showsCursor ? "▍" : ""))
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }
    .padding(10)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.7)
    )
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
  }

  private func table(
    headers: [String],
    rows: [[String]],
    alignments: [AgentMarkdownTableAlignment]
  ) -> some View {
    let layout = AgentMarkdownTableLayout(
      headers: headers,
      rows: rows,
      alignments: alignments
    )
    return ScrollView(.horizontal, showsIndicators: false) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(headers.enumerated()), id: \.offset) { index, value in
            cell(
              value,
              alignment: layout.alignments[safe: index] ?? .leading,
              isHeader: true
            )
          }
        }
        Divider()
          .gridCellColumns(max(layout.columnCount, 1))
        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { index, value in
              cell(
                value,
                alignment: layout.alignments[safe: index] ?? .leading,
                isHeader: false,
                showsCursor: showsCursor && rowIndex == rows.count - 1
              )
            }
          }
        }
      }
      .frame(
        minWidth: CGFloat(max(layout.columnCount, 1)) * 120,
        alignment: .leading
      )
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.7)
      )
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
  }

  private func cell(
    _ value: String,
    alignment: AgentMarkdownTableAlignment,
    isHeader: Bool,
    showsCursor: Bool = false
  ) -> some View {
    AgentMarkdownInlineText(value, showsCursor: showsCursor)
      .font(isHeader ? .callout.weight(.semibold) : .callout)
      .multilineTextAlignment(textAlignment(for: alignment))
      .frame(minWidth: 72, maxWidth: .infinity, alignment: frameAlignment(for: alignment))
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(isHeader ? Color.accentColor.opacity(0.09) : Color.clear)
  }

  private func headingFont(for level: Int) -> Font {
    switch level {
    case 1: return .title2.weight(.bold)
    case 2: return .title3.weight(.semibold)
    case 3: return .headline
    default: return .subheadline.weight(.semibold)
    }
  }

  private func textAlignment(
    for alignment: AgentMarkdownTableAlignment
  ) -> TextAlignment {
    switch alignment {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }

  private func frameAlignment(
    for alignment: AgentMarkdownTableAlignment
  ) -> Alignment {
    switch alignment {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }
}

extension Collection {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
