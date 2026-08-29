import Foundation

extension AgentMarkdownDocumentParser {
  static func table(
    _ lines: [String],
    from index: Int
  ) -> (content: AgentMarkdownBlockContent, nextIndex: Int)? {
    guard index + 1 < lines.count,
      let headers = tableCells(in: lines[index]),
      headers.count > 1,
      let delimiter = tableCells(in: lines[index + 1]),
      delimiter.count == headers.count,
      delimiter.allSatisfy({ tableAlignment($0) != nil })
    else { return nil }
    let alignments = delimiter.compactMap(tableAlignment)

    var rows: [[String]] = []
    var nextIndex = index + 2
    while nextIndex < lines.count,
      !isBlank(lines[nextIndex]),
      !isBlockStart(lines, at: nextIndex),
      let values = tableCells(in: lines[nextIndex]),
      values.count > 1
    {
      rows.append(normalizedRow(values, count: headers.count))
      nextIndex += 1
    }
    return (
      .table(
        headers: headers,
        rows: rows,
        alignments: alignments
      ),
      nextIndex
    )
  }

  static func tableCells(in line: String) -> [String]? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("|") else { return nil }
    var characters = Array(trimmed)
    if characters.first == "|" { characters.removeFirst() }
    if characters.last == "|" { characters.removeLast() }
    guard !characters.isEmpty else { return nil }

    var cells: [String] = []
    var value = ""
    var escaped = false
    var inCode = false
    for character in characters {
      if escaped {
        value.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "`" {
        inCode.toggle()
        value.append(character)
      } else if character == "|", !inCode {
        cells.append(value.trimmingCharacters(in: .whitespaces))
        value.removeAll(keepingCapacity: true)
      } else {
        value.append(character)
      }
    }
    if escaped { value.append("\\") }
    cells.append(value.trimmingCharacters(in: .whitespaces))
    return cells.count > 1 ? cells : nil
  }

  static func tableAlignment(_ value: String) -> AgentMarkdownTableAlignment? {
    let text = value.trimmingCharacters(in: .whitespaces)
    let characters = Array(text)
    guard characters.count >= 3,
      characters.allSatisfy({ $0 == "-" || $0 == ":" }),
      characters.first == "-" || characters.first == ":",
      characters.last == "-" || characters.last == ":",
      characters.filter({ $0 == "-" }).count >= 3
    else { return nil }
    switch (characters.first == ":", characters.last == ":") {
    case (true, true): return .center
    case (false, true): return .trailing
    default: return .leading
    }
  }

  static func normalizedRow(_ values: [String], count: Int) -> [String] {
    if values.count == count { return values }
    if values.count > count { return Array(values.prefix(count)) }
    return values + Array(repeating: "", count: count - values.count)
  }

  static func parseList(
    _ lines: [String],
    from index: Int,
    marker: ListMarker
  ) -> (ordered: Bool, items: [String], nextIndex: Int) {
    var items = [marker.text]
    var nextIndex = index + 1
    while nextIndex < lines.count {
      if let next = listMarker(in: lines[nextIndex]),
        next.ordered == marker.ordered,
        next.indent == marker.indent
      {
        items.append(next.text)
        nextIndex += 1
      } else if isBlank(lines[nextIndex]) {
        let lookahead = nextIndex + 1
        guard lookahead < lines.count,
          let next = listMarker(in: lines[lookahead]),
          next.ordered == marker.ordered,
          next.indent == marker.indent
        else { break }
        nextIndex = lookahead
      } else if leadingSpaces(in: Array(lines[nextIndex])) > marker.indent {
        items[items.count - 1] += "\n" + lines[nextIndex].trimmingCharacters(in: .whitespaces)
        nextIndex += 1
      } else {
        break
      }
    }
    return (marker.ordered, items, nextIndex)
  }

  static func listMarker(in line: String) -> ListMarker? {
    let characters = Array(line)
    let indent = leadingSpaces(in: characters)
    guard indent <= 3, indent < characters.count else { return nil }
    let first = characters[indent]
    if first == "-" || first == "+" || first == "*" {
      guard indent + 1 < characters.count, characters[indent + 1].isWhitespace else {
        return nil
      }
      let text = String(characters.dropFirst(indent + 1))
        .trimmingCharacters(in: .whitespaces)
      return ListMarker(ordered: false, indent: indent, text: text)
    }
    guard first.isNumber else { return nil }
    var end = indent
    while end < characters.count, characters[end].isNumber { end += 1 }
    guard end < characters.count, characters[end] == "." || characters[end] == ")",
      end + 1 < characters.count,
      characters[end + 1].isWhitespace
    else { return nil }
    let text = String(characters.dropFirst(end + 1)).trimmingCharacters(in: .whitespaces)
    return ListMarker(ordered: true, indent: indent, text: text)
  }

  static func parseQuote(
    _ lines: [String],
    from index: Int
  ) -> (text: String, nextIndex: Int) {
    var values: [String] = []
    var nextIndex = index
    while nextIndex < lines.count {
      if let value = quoteText(in: lines[nextIndex]) {
        values.append(value)
        nextIndex += 1
      } else if isBlank(lines[nextIndex]), nextIndex + 1 < lines.count,
        quoteText(in: lines[nextIndex + 1]) != nil
      {
        values.append("")
        nextIndex += 1
      } else {
        break
      }
    }
    return (values.joined(separator: "\n"), nextIndex)
  }

  static func quoteText(in line: String) -> String? {
    let characters = Array(line)
    let indent = leadingSpaces(in: characters)
    guard indent <= 3, indent < characters.count, characters[indent] == ">" else {
      return nil
    }
    var value = String(characters.dropFirst(indent + 1))
    if value.first == " " { value.removeFirst() }
    return value
  }

  static func parseParagraph(
    _ lines: [String],
    from index: Int
  ) -> (text: String, nextIndex: Int) {
    var values = [lines[index]]
    var nextIndex = index + 1
    while nextIndex < lines.count, !isBlank(lines[nextIndex]),
      !isBlockStart(lines, at: nextIndex)
    {
      values.append(lines[nextIndex])
      nextIndex += 1
    }
    return (values.joined(separator: "\n"), nextIndex)
  }

  static func isBlockStart(_ lines: [String], at index: Int) -> Bool {
    if fence(in: lines[index]) != nil || heading(in: lines[index]) != nil {
      return true
    }
    if listMarker(in: lines[index]) != nil || quoteText(in: lines[index]) != nil {
      return true
    }
    if isThematicBreak(lines[index]) { return true }
    return table(lines, from: index) != nil
  }

  static func isThematicBreak(_ line: String) -> Bool {
    let value = line.replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "\t", with: "")
    guard value.count >= 3 else { return false }
    return value.allSatisfy { $0 == "-" || $0 == "_" || $0 == "*" }
  }

  static func leadingSpaces(in characters: [Character]) -> Int {
    var index = 0
    while index < characters.count, characters[index] == " " { index += 1 }
    return index
  }

  static func runLength(
    of marker: Character,
    in characters: [Character],
    from index: Int
  ) -> Int {
    var end = index
    while end < characters.count, characters[end] == marker { end += 1 }
    return end - index
  }

  static func isBlank(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
