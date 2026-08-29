import Foundation
import SwiftUI
import BridgeServiceAppCore

struct AgentMarkdownText: View {
  let content: String
  let isStreaming: Bool
  let fillsWidth: Bool
  @State private var document: AgentMarkdownDocument?
  @State private var parsedContent = ""

  init(_ content: String, isStreaming: Bool = false, fillsWidth: Bool = false) {
    self.content = content
    self.isStreaming = isStreaming
    self.fillsWidth = fillsWidth
    _document = State(initialValue: nil)
    _parsedContent = State(initialValue: "")
  }

  var body: some View {
    Group {
      if !isStreaming, parsedContent == content, let document {
        AgentMarkdownDocumentView(
          document: document,
          isStreaming: false,
          fillsWidth: fillsWidth
        )
      } else {
        fallbackText
      }
    }
    .task(id: isStreaming ? nil : content) {
      guard !isStreaming else { return }
      let nextDocument = document?.updating(content: content) ?? AgentMarkdownDocument(content)
      guard !Task.isCancelled else { return }
      document = nextDocument
      parsedContent = content
    }
  }

  private var fallbackText: some View {
    Text(AgentMarkdownFallback.safePlainTextFallback(from: content) + (isStreaming ? "▍" : ""))
      .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
  }

  nonisolated static func attributedString(from content: String) -> AttributedString? {
    try? AttributedString(
      markdown: repairingIncompleteMarkup(in: content),
      options: .init(interpretedSyntax: .full)
    )
  }

  nonisolated static func inlineAttributedString(from content: String) -> AttributedString? {
    try? AttributedString(
      markdown: repairingIncompleteMarkup(in: content),
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )
  }

  nonisolated fileprivate static func repairingIncompleteMarkup(in content: String) -> String {
    var result = content
    let markers = markdownMarkerCounts(in: content)
    if markers.fences.isMultiple(of: 2) == false {
      result += "\n```"
      return result
    }
    if markers.backticks.isMultiple(of: 2) == false { result += "`" }
    if markers.strong.isMultiple(of: 2) == false { result += "**" }
    if markers.emphasis.isMultiple(of: 2) == false { result += "*" }
    return result
  }

  nonisolated private static func markdownMarkerCounts(in content: String) -> (
    fences: Int, backticks: Int, strong: Int, emphasis: Int
  ) {
    let characters = Array(content)
    var index = 0
    var lineStart = true
    var insideFence = false
    var insideInlineCode = false
    var counts = (fences: 0, backticks: 0, strong: 0, emphasis: 0)
    while index < characters.count {
      let character = characters[index]
      if character == "\\" {
        index += min(2, characters.count - index)
        lineStart = false
        continue
      }
      if character == "`" {
        let run = markerRunLength("`", at: index, in: characters)
        if run >= 3 {
          counts.fences += 1
          insideFence.toggle()
        } else if !insideFence {
          counts.backticks += run
          insideInlineCode.toggle()
        }
        index += run
        lineStart = false
        continue
      }
      if character == "*", !insideFence, !insideInlineCode {
        let run = markerRunLength("*", at: index, in: characters)
        if run >= 2 {
          counts.strong += run / 2
          counts.emphasis += run % 2
        } else if !(lineStart && nextCharacterIsWhitespace(at: index, in: characters)),
          adjacentCharacterIsNonWhitespace(at: index, in: characters)
        {
          counts.emphasis += 1
        }
        index += run
        lineStart = false
        continue
      }
      if character == "\n" {
        lineStart = true
      } else if !character.isWhitespace {
        lineStart = false
      }
      index += 1
    }
    return counts
  }

  nonisolated private static func markerRunLength(
    _ marker: Character,
    at index: Int,
    in characters: [Character]
  ) -> Int {
    var end = index
    while end < characters.count, characters[end] == marker { end += 1 }
    return end - index
  }

  nonisolated private static func nextCharacterIsWhitespace(
    at index: Int,
    in characters: [Character]
  ) -> Bool {
    let next = index + 1
    return next < characters.count && characters[next].isWhitespace
  }

  nonisolated private static func adjacentCharacterIsNonWhitespace(
    at index: Int,
    in characters: [Character]
  ) -> Bool {
    let previousIsNonWhitespace = index > 0 && !characters[index - 1].isWhitespace
    let next = index + 1
    let nextIsNonWhitespace = next < characters.count && !characters[next].isWhitespace
    return previousIsNonWhitespace || nextIsNonWhitespace
  }
}

struct AgentMarkdownInlineText: View {
  let content: String
  let showsCursor: Bool
  @State private var rendered: AttributedString?
  @State private var renderedContent = ""

  init(_ content: String, showsCursor: Bool = false) {
    self.content = content
    self.showsCursor = showsCursor
    _rendered = State(initialValue: nil)
    _renderedContent = State(initialValue: "")
  }

  var body: some View {
    displayedText
      .task(id: content) {
        let nextValue = Self.renderedValue(for: content)
        guard !Task.isCancelled else { return }
        rendered = nextValue
        renderedContent = content
      }
  }

  private var displayedText: Text {
    let fallback = AgentMarkdownFallback.safePlainTextFallback(from: content)
    let base =
      renderedContent == content
      ? rendered.map { Text($0) } ?? Text(fallback)
      : Text(fallback)
    guard showsCursor else { return base }
    return base + Text("▍").foregroundColor(.accentColor)
  }

  private static func renderedValue(for content: String) -> AttributedString {
    AgentMarkdownText.inlineAttributedString(from: content)
      ?? AttributedString(AgentMarkdownFallback.safePlainTextFallback(from: content))
  }
}
