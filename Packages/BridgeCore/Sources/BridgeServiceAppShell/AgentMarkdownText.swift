import Foundation
import SwiftUI

struct AgentMarkdownText: View {
  let content: String
  let isStreaming: Bool

  init(_ content: String, isStreaming: Bool = false) {
    self.content = content
    self.isStreaming = isStreaming
  }

  var body: some View {
    renderedText
  }

  private var renderedText: Text {
    let text =
      Self.attributedString(from: content).map(Text.init)
      ?? Text(Self.plainTextFallback(from: content))
    guard isStreaming else { return text }
    return text + Text("▍").foregroundColor(.accentColor)
  }

  nonisolated static func attributedString(from content: String) -> AttributedString? {
    try? AttributedString(
      markdown: repairingIncompleteMarkup(in: content),
      options: .init(interpretedSyntax: .full)
    )
  }

  nonisolated private static func repairingIncompleteMarkup(in content: String) -> String {
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

  nonisolated private static func plainTextFallback(from content: String) -> String {
    content
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        var value = String(line)
        while value.first == "#" { value.removeFirst() }
        if value.first == " " { value.removeFirst() }
        if value.hasPrefix("- ") || value.hasPrefix("* ") { value.removeFirst(2) }
        return
          value
          .replacingOccurrences(of: "**", with: "")
          .replacingOccurrences(of: "`", with: "")
      }
      .joined(separator: "\n")
  }
}
