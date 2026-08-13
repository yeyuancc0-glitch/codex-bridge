import SwiftUI

struct PageHeader: View {
  let title: String
  let subtitle: String
  let refreshAction: (() async -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: BridgeTheme.spacingRegular) {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
        Text(title)
          .font(.title2.weight(.semibold))
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: BridgeTheme.spacingSection)
      if let refreshAction {
        Button {
          Task { await refreshAction() }
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .help("刷新此页面的真实状态")
      }
    }
    .accessibilityElement(children: .contain)
  }
}

struct StatusLabel: View {
  let status: PresentationStatus

  var body: some View {
    Label(status.label, systemImage: status.systemImage)
      .foregroundStyle(status.tint)
      .accessibilityLabel(status.accessibilitySummary)
  }
}

struct StatusRow: View {
  let title: String
  let detail: String
  let status: PresentationStatus

  var body: some View {
    HStack(alignment: .top, spacing: BridgeTheme.spacingRegular) {
      Image(systemName: status.systemImage)
        .foregroundStyle(status.tint)
        .frame(width: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
        Text(title)
          .font(.body.weight(.medium))
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer(minLength: BridgeTheme.spacingRegular)
      Text(status.label)
        .font(.subheadline)
        .foregroundStyle(status.tint)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)，\(status.accessibilitySummary)，\(detail)")
  }
}

struct SectionHeading: View {
  let title: String
  let detail: String?

  init(_ title: String, detail: String? = nil) {
    self.title = title
    self.detail = detail
  }

  var body: some View {
    VStack(alignment: .leading, spacing: BridgeTheme.spacingTight) {
      Text(title)
        .font(.headline)
      if let detail {
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct MetadataRow: View {
  let label: String
  let value: String
  var monospaced = false

  var body: some View {
    LabeledContent(label) {
      Text(value)
        .font(monospaced ? .system(.body, design: .monospaced) : .body)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
    }
  }
}

struct EvidenceText: View {
  let text: String

  var body: some View {
    ScrollView(.horizontal) {
      Text(text)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BridgeTheme.spacingRegular)
    }
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: BridgeTheme.compactCornerRadius))
  }
}

struct BulletList: View {
  let items: [String]
  let emptyMessage: String

  var body: some View {
    if items.isEmpty {
      Text(emptyMessage)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: BridgeTheme.spacingRegular) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: BridgeTheme.spacingRegular) {
            Image(systemName: "circle.fill")
              .font(.system(size: 5))
              .accessibilityHidden(true)
            Text(item)
              .textSelection(.enabled)
          }
        }
      }
    }
  }
}

struct LoadStateView<Value: Equatable & Sendable, Content: View>: View {
  let state: PresentationLoadState<Value>
  let retry: () async -> Void
  @ViewBuilder let content: (Value) -> Content

  var body: some View {
    switch state {
    case .loading(let message):
      ContentUnavailableView {
        ProgressView()
          .controlSize(.large)
      } description: {
        Text(message)
      }
      .accessibilityLabel(message)
    case .empty(let empty):
      ContentUnavailableView(
        empty.title, systemImage: empty.systemImage, description: Text(empty.message))
    case .failed(let error):
      ContentUnavailableView {
        Label(error.title, systemImage: "exclamationmark.triangle")
      } description: {
        Text(error.message)
      } actions: {
        Button(error.recoveryActionTitle) {
          Task { await retry() }
        }
        .keyboardShortcut("r", modifiers: .command)
      }
    case .ready(let value):
      content(value)
    }
  }
}

extension Date {
  var bridgeFormatted: String {
    formatted(date: .abbreviated, time: .shortened)
  }
}
