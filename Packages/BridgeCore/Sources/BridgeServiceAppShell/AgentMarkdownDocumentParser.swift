import Foundation

enum AgentMarkdownDocumentParser {
  struct Fence {
    let marker: Character
    let length: Int
    let language: String?
  }

  struct ListMarker {
    let ordered: Bool
    let indent: Int
    let text: String
  }

  static func parse(_ content: String) -> [AgentMarkdownBlock] {
    let lines = normalizedLines(content)
    var blocks: [AgentMarkdownBlock] = []
    var index = 0

    while index < lines.count {
      if isBlank(lines[index]) {
        index += 1
      } else if let fence = fence(in: lines[index]) {
        let result = parseFence(lines, from: index, fence: fence)
        append(result.content, to: &blocks)
        index = result.nextIndex
      } else if let heading = heading(in: lines[index]) {
        append(.heading(level: heading.level, text: heading.text), to: &blocks)
        index += 1
      } else if let table = table(lines, from: index) {
        append(table.content, to: &blocks)
        index = table.nextIndex
      } else if let marker = listMarker(in: lines[index]) {
        let result = parseList(lines, from: index, marker: marker)
        let content: AgentMarkdownBlockContent =
          result.ordered
          ? .orderedList(result.items)
          : .unorderedList(result.items)
        append(content, to: &blocks)
        index = result.nextIndex
      } else if quoteText(in: lines[index]) != nil {
        let result = parseQuote(lines, from: index)
        append(.quote(result.text), to: &blocks)
        index = result.nextIndex
      } else if isThematicBreak(lines[index]) {
        append(.thematicBreak, to: &blocks)
        index += 1
      } else {
        let result = parseParagraph(lines, from: index)
        append(.paragraph(result.text), to: &blocks)
        index = result.nextIndex
      }
    }
    return blocks
  }

  static func normalizedLines(_ content: String) -> [String] {
    content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  static func append(
    _ content: AgentMarkdownBlockContent,
    to blocks: inout [AgentMarkdownBlock]
  ) {
    blocks.append(AgentMarkdownBlock(id: "block-\(blocks.count)", content: content))
  }

  static func parseFence(
    _ lines: [String],
    from index: Int,
    fence: Fence
  ) -> (content: AgentMarkdownBlockContent, nextIndex: Int) {
    var end = index + 1
    while end < lines.count && !isClosingFence(lines[end], matching: fence) {
      end += 1
    }
    let text = lines[(index + 1)..<end].joined(separator: "\n")
    let nextIndex = end < lines.count ? end + 1 : end
    return (.code(language: fence.language, text: text), nextIndex)
  }

  static func fence(in line: String) -> Fence? {
    let characters = Array(line)
    let indent = leadingSpaces(in: characters)
    guard indent <= 3, indent < characters.count else { return nil }
    let marker = characters[indent]
    guard marker == "`" || marker == "~" else { return nil }
    let length = runLength(of: marker, in: characters, from: indent)
    guard length >= 3 else { return nil }
    let suffix = String(characters.dropFirst(indent + length))
    if marker == "`", suffix.contains("`") { return nil }
    let language = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    return Fence(marker: marker, length: length, language: language.isEmpty ? nil : language)
  }

  static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
    let characters = Array(line)
    let indent = leadingSpaces(in: characters)
    guard indent <= 3, indent < characters.count, characters[indent] == fence.marker else {
      return false
    }
    let length = runLength(of: fence.marker, in: characters, from: indent)
    guard length >= fence.length else { return false }
    return String(characters.dropFirst(indent + length))
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }

  static func heading(in line: String) -> (level: Int, text: String)? {
    let characters = Array(line)
    let indent = leadingSpaces(in: characters)
    guard indent <= 3, indent < characters.count, characters[indent] == "#" else {
      return nil
    }
    let length = runLength(of: "#", in: characters, from: indent)
    guard length <= 6 else { return nil }
    guard indent + length == characters.count || characters[indent + length].isWhitespace else {
      return nil
    }
    let rawText = String(characters.dropFirst(indent + length))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (length, headingText(rawText))
  }

  static func headingText(_ text: String) -> String {
    var result = text
    while result.last == "#" {
      let before = result.dropLast()
      guard before.last?.isWhitespace == true else { break }
      result = String(before).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return result
  }
}
